import Foundation
import NIOSSH
import NIOCore

/// Bounds concurrent one-shot command channels so bursts stay under sshd's
/// per-connection session limit (`MaxSessions`, default 10). Commands over the
/// cap queue until a slot frees.
final class CommandGate {
    private let maxInFlight: Int
    private let lock = NSLock()
    private var inFlight = 0
    private var queued: [() -> Void] = []

    init(maxInFlight: Int) {
        self.maxInFlight = maxInFlight
    }

    /// Runs `work` immediately when under the cap, otherwise queues it.
    /// `work` must call its `finished` callback exactly once to release the slot.
    func run(_ work: @escaping (_ finished: @escaping () -> Void) -> Void) {
        let finished = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.queued.isEmpty {
                self.inFlight -= 1
                self.lock.unlock()
            } else {
                let next = self.queued.removeFirst()
                self.lock.unlock()
                // Hop off the completing thread so a backlog drains iteratively
                // instead of re-entering (and growing) this stack.
                DispatchQueue.global(qos: .userInitiated).async(execute: next)
            }
        }

        let job = { work(finished) }
        lock.lock()
        if inFlight < maxInFlight {
            inFlight += 1
            lock.unlock()
            job()
        } else {
            queued.append(job)
            lock.unlock()
        }
    }
}

/// Runs one AppleScript on its own throwaway SSH exec channel: bash-wraps it,
/// opens a session channel, execs `osascript`, completes with the output, and
/// closes the channel. Fully isolated — the command can block (e.g. on a macOS
/// permission dialog) without delaying any other command.
///
/// This is the compatibility transport's per-command engine, shared so the
/// streaming transport can run isolated commands over its own connection too.
enum EphemeralCommandChannel {

    static func run(
        _ appleScript: String,
        on connection: Channel,
        description: String?,
        onConnectionLoss: (() -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let command = ShellCommandUtilities.wrapAppleScriptForBash(appleScript)
        sshLog("Ephemeral channel: \(description ?? "command")")

        let childPromise = connection.eventLoop.makePromise(of: Channel.self)
        var commandChannel: Channel?

        connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            sshHandler.createChannel(childPromise) { (childChannel: Channel, channelType: SSHChannelType) -> EventLoopFuture<Void> in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                let commandHandler = SSHCommandHandler()
                commandHandler.pendingCommandPromise = childChannel.eventLoop.makePromise(of: String.self)
                return childChannel.pipeline.addHandlers([
                    commandHandler,
                    SSHChannelErrorHandler()
                ])
            }

            return childPromise.futureResult.map { channel in
                commandChannel = channel
                return channel
            }.flatMapError { error in
                if SSHError.isConnectionLoss(error) {
                    onConnectionLoss?()
                    return connection.eventLoop.makeFailedFuture(SSHError.channelError("Connection lost"))
                }
                return connection.eventLoop.makeFailedFuture(error)
            }
        }.flatMap { channel -> EventLoopFuture<String> in
            channel.pipeline.handler(type: SSHCommandHandler.self).flatMap { handler in
                guard let promise = handler.pendingCommandPromise else {
                    return channel.eventLoop.makeFailedFuture(SSHError.channelError("Command promise not set"))
                }
                let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
                return channel.triggerUserOutboundEvent(execRequest).flatMap { _ in
                    // Matches the streaming executor's watchdog: AppleScript can
                    // legitimately run long (System Events, app foregrounding).
                    channel.eventLoop.scheduleTask(in: .seconds(6)) {
                        if let pendingPromise = handler.pendingCommandPromise {
                            sshLog("⏰ Ephemeral command timed out after 6 seconds")
                            pendingPromise.fail(SSHError.timeout)
                            channel.close(promise: nil)
                        }
                    }
                    return promise.futureResult
                }
            }
        }.whenComplete { result in
            if let channel = commandChannel {
                channel.close(promise: nil)
            }
            switch result {
            case .success(let output):
                completion(.success(output))
            case .failure(let error):
                if SSHError.isConnectionLoss(error) {
                    onConnectionLoss?()
                    completion(.failure(SSHError.channelError("Connection lost")))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }
}

/// Reads a single command's output on a per-command channel; accumulates
/// stdout/stderr and completes the promise when the channel closes.
///
/// Close is the only safe completion point. Completing on the first output
/// chunk let split replies/stderr noise masquerade as the result, and
/// completing on the exit-status *event* raced the data itself — NIOSSH
/// delivers channel events immediately while stdout can still be queued in the
/// child channel's read buffer, so commands intermittently resolved as '' under
/// concurrent channels (empty heartbeat replies → spurious reconnect loops,
/// unparseable volume/status). By channel close, all delivered data has
/// arrived; the exit-status just marks a normal finish, which may legitimately
/// have no output at all (e.g. `set volume output volume 40`).
final class SSHCommandHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    var pendingCommandPromise: EventLoopPromise<String>?
    private var buffer = ""
    private var sawExitStatus = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        switch channelData.type {
        case .channel:
            if case .byteBuffer(let buffer) = channelData.data,
               let output = buffer.getString(at: 0, length: buffer.readableBytes) {
                self.buffer += output
            }
        case .stdErr:
            if case .byteBuffer(let buffer) = channelData.data,
               let error = buffer.getString(at: 0, length: buffer.readableBytes) {
                self.buffer += "[Error] " + error
            }
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExitStatus {
            sawExitStatus = true
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A close with an exit-status is a completed command; a close without
        // one — even with partial output buffered — is a drop mid-command.
        if let promise = pendingCommandPromise {
            pendingCommandPromise = nil
            if sawExitStatus {
                promise.succeed(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer = ""
            } else {
                promise.fail(SSHError.channelError("Connection closed"))
            }
        }
        context.fireChannelInactive()
    }

    /// Guaranteed teardown hook: a channel whose open is refused or aborted
    /// never becomes active, so `channelInactive` is never delivered and a
    /// still-pending promise would deallocate unfulfilled — NIO's debug leak
    /// assertion aborts the app. For channels that did go active this runs
    /// after `channelInactive`, where the promise is already nil.
    func handlerRemoved(context: ChannelHandlerContext) {
        if let promise = pendingCommandPromise {
            pendingCommandPromise = nil
            promise.fail(SSHError.channelError("Connection closed"))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let promise = pendingCommandPromise {
            promise.fail(error)
            pendingCommandPromise = nil
        }
        context.close(promise: nil)
    }
}
