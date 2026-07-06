import Foundation
import NIOSSH
import NIOCore
import NIOPosix

/// **Compatibility transport.** Opens a fresh SSH channel and runs one
/// `osascript` per command — no PTY, no persistent interpreter, no sentinels.
/// Selectable in Preferences (and used as an auto-fallback) for Macs where the
/// streaming transport misbehaves.
///
/// Conforms to `SSHClientProtocol` by ignoring `channelKey` and bash-wrapping the
/// raw AppleScript (`AppController` sends the same raw scripts to both transports;
/// only the framing/execution differs). The connect sequence, auth handling, and
/// error classification are shared with the streaming client via
/// `SSHTransportConnector` / `SSHError.classify`, so they are not redeclared here.
class LegacySSHClient: SSHClientProtocol {
    private var group: EventLoopGroup
    private var connection: Channel?
    private var session: Channel?

    /// Bounds concurrent per-command channels. sshd caps sessions per
    /// connection (`MaxSessions`, default 10), and a parallel status sweep +
    /// heartbeat + a user action can brush against that limit — a refused
    /// channel open surfaces as a failed command. Extras queue briefly instead.
    private let maxInFlightCommands = 5
    private let commandGateLock = NSLock()
    private var inFlightCommands = 0
    private var queuedCommands: [() -> Void] = []

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        disconnect()
        try? group.syncShutdownGracefully()
    }

    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let connectionId = String(UUID().uuidString.prefix(8))
        sshLog("🆔 [\(connectionId)] LegacySSHClient: Starting connection process")

        if connection != nil {
            sshLog("Cleaning up existing connection before reconnecting")
            disconnect()
        }

        let isLocal = host.contains(".local")
        let connectionType = isLocal ? "SSH over Bonjour (.local)" : "SSH over TCP/IP"
        sshLog("Attempting TCP connection: \(connectionType)")

        SSHTransportConnector.connect(
            group: group,
            host: host,
            username: username,
            password: password,
            connectionId: connectionId,
            makeChildHandlers: { [SSHCommandHandler(), SSHChannelErrorHandler()] }
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let established):
                // Keep the auth-gating session channel as the long-lived session.
                self.connection = established.connection
                self.session = established.session
                sshLog("✓ [\(connectionId)] SSH connection fully established")
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - SSHClientProtocol

    /// Each command opens its own channel and runs concurrently, so a bulk
    /// status refresh doesn't queue behind itself — unlike the streaming transport.
    var serializesAppCommands: Bool { false }

    /// The streaming transport reuses channels keyed by `channelKey`; the legacy
    /// transport ignores it (fresh channel per command) but bash-wraps the raw
    /// AppleScript the caller supplies.
    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let wrapped = ShellCommandUtilities.wrapAppleScriptForBash(command)
        // The heartbeat is the health signal — it must never queue behind a
        // status sweep, so it bypasses the gate (worst case 5 + 1 sessions,
        // still well under sshd's MaxSessions).
        if channelKey == "heartbeat" {
            executeCommandOnNewChannel(wrapped, description: description, completion: completion)
            return
        }
        runGated { [weak self] finished in
            guard let self else {
                finished()
                completion(.failure(SSHError.channelNotConnected))
                return
            }
            self.executeCommandOnNewChannel(wrapped, description: description) { result in
                finished()
                completion(result)
            }
        }
    }

    /// Runs `work` immediately when under the in-flight cap, otherwise queues
    /// it. `work` must call its `finished` callback exactly once (the command
    /// paths all funnel through a once-only promise) to release the slot.
    private func runGated(_ work: @escaping (_ finished: @escaping () -> Void) -> Void) {
        let finished = { [weak self] in
            guard let self else { return }
            self.commandGateLock.lock()
            if self.queuedCommands.isEmpty {
                self.inFlightCommands -= 1
                self.commandGateLock.unlock()
            } else {
                let next = self.queuedCommands.removeFirst()
                self.commandGateLock.unlock()
                // Hop off the completing thread so a sustained backlog drains
                // iteratively instead of re-entering (and growing) this stack.
                DispatchQueue.global(qos: .userInitiated).async(execute: next)
            }
        }

        let run = { work(finished) }
        commandGateLock.lock()
        if inFlightCommands < maxInFlightCommands {
            inFlightCommands += 1
            commandGateLock.unlock()
            run()
        } else {
            queuedCommands.append(run)
            commandGateLock.unlock()
        }
    }

    private func executeCommandOnNewChannel(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let connection = connection else {
            completion(.failure(SSHError.channelNotConnected))
            return
        }

        let commandDesc = description ?? "Running command with new channel"
        sshLog("Legacy: executing with new channel: \(commandDesc)")

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
                    self.disconnect()
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
                            sshLog("⏰ Legacy command timed out after 6 seconds")
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
                    self.disconnect()
                    completion(.failure(SSHError.channelError("Connection lost")))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    func disconnect() {
        if let session = session {
            let exitRequest = SSHChannelRequestEvent.ExecRequest(command: "exit", wantReply: false)
            _ = session.triggerUserOutboundEvent(exitRequest)
            session.pipeline.handler(type: SSHCommandHandler.self).whenSuccess { handler in
                handler.pendingCommandPromise?.fail(SSHError.channelError("Connection closed"))
            }
        }

        session?.close(promise: nil)
        session = nil
        connection?.close(promise: nil)
        connection = nil
        sshLog("⚰︎ LegacySSHClient disconnected and cleaned up")
    }
}

/// Reads a single command's output on a legacy per-command channel; accumulates
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
        // Only an exit-status marks a completed command. A close without one —
        // even with partial output buffered — is a drop mid-command; succeeding
        // with truncated output would render a wrong state and skip the
        // connection-loss handling upstream.
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
