import Foundation
import NIOSSH
import NIOCore
import NIOPosix

/// **Legacy (compatibility) transport.** Opens a fresh SSH channel and runs one
/// `osascript` per command — no PTY, no persistent interpreter, no sentinels.
/// Ported from the pre-streaming `SSHClient`; kept isolated here as a fallback
/// selectable in Preferences for Macs where the streaming transport misbehaves.
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
        sshLog("Host: \(host.prefix(10))***")
        sshLog("Username: \(username.prefix(3))***")

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
            makeChildHandlers: { [SSHCommandHandler(), LegacyErrorHandler()] }
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
        executeCommandOnNewChannel(wrapped, description: description, completion: completion)
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
                    LegacyErrorHandler()
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
                    channel.eventLoop.scheduleTask(in: .seconds(5)) {
                        if let pendingPromise = handler.pendingCommandPromise {
                            sshLog("⏰ Legacy command timed out after 5 seconds")
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

/// Reads a single command's output on a legacy per-command channel; completes the
/// promise once output arrives or the channel closes.
final class SSHCommandHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    var pendingCommandPromise: EventLoopPromise<String>?
    private var buffer = ""
    private var hasReceivedOutput = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        switch channelData.type {
        case .channel:
            if case .byteBuffer(let buffer) = channelData.data,
               let output = buffer.getString(at: 0, length: buffer.readableBytes) {
                self.buffer += output
                hasReceivedOutput = true
                if !output.isEmpty { completeCommand() }
            }
        case .stdErr:
            if case .byteBuffer(let buffer) = channelData.data,
               let error = buffer.getString(at: 0, length: buffer.readableBytes) {
                self.buffer += "[Error] " + error
                hasReceivedOutput = true
                completeCommand()
            }
        default:
            break
        }
    }

    private func completeCommand() {
        if hasReceivedOutput {
            let result = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingCommandPromise?.succeed(result)
            pendingCommandPromise = nil
            buffer = ""
            hasReceivedOutput = false
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let promise = pendingCommandPromise {
            promise.fail(SSHError.channelError("Connection closed"))
            pendingCommandPromise = nil
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let promise = pendingCommandPromise {
            promise.fail(error)
            pendingCommandPromise = nil
        }
        context.close(promise: nil)
    }
}

private final class LegacyErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
