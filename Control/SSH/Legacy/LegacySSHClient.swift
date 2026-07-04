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
/// only the framing/execution differs). Shared types (`SSHError`,
/// `PasswordAuthDelegate`, `AcceptAllHostKeysDelegate`) live with the streaming
/// `SSHClient`, so they are not redeclared here.
class LegacySSHClient: SSHClientProtocol {
    private var group: EventLoopGroup
    private var connection: Channel?
    private var session: Channel?
    private var authDelegate: PasswordAuthDelegate?
    private var hasCompletedConnection = false

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? group.syncShutdownGracefully()
        disconnect()
    }

    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        hasCompletedConnection = false

        let connectionId = UUID().uuidString.prefix(8)
        sshLog("🆔 [\(connectionId)] LegacySSHClient: Starting connection process")
        sshLog("Host: \(host.prefix(10))***")
        sshLog("Username: \(username.prefix(3))***")

        if connection != nil {
            sshLog("Cleaning up existing connection before reconnecting")
            disconnect()
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !self.hasCompletedConnection else { return }
            sshLog("❌ [\(connectionId)] Connection timed out after 5 seconds")
            self.hasCompletedConnection = true
            self.disconnect()
            completion(.failure(SSHError.timeout))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)

        let authDelegate = PasswordAuthDelegate(username: username, password: password)
        authDelegate.onAuthFailure = { [weak self] in
            guard let self = self, !self.hasCompletedConnection else { return }
            timeout.cancel()
            sshLog("❌ [\(connectionId)] Authentication failed")
            self.hasCompletedConnection = true
            self.disconnect()
            completion(.failure(SSHError.authenticationFailed))
        }
        self.authDelegate = authDelegate

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(4))
            .channelInitializer { [weak self] channel in
                self?.setupChannel(channel, authDelegate: authDelegate) ?? channel.eventLoop.makeFailedFuture(SSHError.channelError("Failed to setup channel"))
            }

        let isLocal = host.contains(".local")
        let connectionType = isLocal ? "SSH over Bonjour (.local)" : "SSH over TCP/IP"
        sshLog("Attempting TCP connection: \(connectionType)")

        bootstrap.connect(host: host, port: 22).whenComplete { [weak self] result in
            guard let self = self, !self.hasCompletedConnection else {
                sshLog("⚠️ [\(connectionId)] Connection attempt completed but already handled, ignoring result")
                return
            }
            timeout.cancel()

            switch result {
            case .success(let channel):
                sshLog("✓ [\(connectionId)] TCP connection established")
                self.connection = channel
                // Opening a session gates success on auth completing (a channel
                // can't open until authenticated), matching the original client.
                self.createSession { [weak self] sessionResult in
                    guard let self = self, !self.hasCompletedConnection else {
                        sshLog("⚠️ [\(connectionId)] Session creation completed but already handled, ignoring result")
                        return
                    }

                    switch sessionResult {
                    case .success:
                        if authDelegate.authFailed {
                            self.hasCompletedConnection = true
                            completion(.failure(SSHError.authenticationFailed))
                        } else {
                            sshLog("✓ [\(connectionId)] SSH connection fully established")
                            self.hasCompletedConnection = true
                            completion(.success(()))
                        }
                    case .failure(let error):
                        sshLog("❌ [\(connectionId)] Session creation failed: \(error)")
                        self.hasCompletedConnection = true
                        completion(.failure(error))
                    }
                }

            case .failure(let error):
                sshLog("❌ [\(connectionId)] TCP connection failed: \(error.localizedDescription)")
                self.hasCompletedConnection = true
                completion(.failure(self.processError(error)))
            }
        }
    }

    private func setupChannel(_ channel: Channel, authDelegate: PasswordAuthDelegate) -> EventLoopFuture<Void> {
        let sshHandler = NIOSSHHandler(
            role: .client(.init(
                userAuthDelegate: authDelegate,
                serverAuthDelegate: AcceptAllHostKeysDelegate()
            )),
            allocator: channel.allocator,
            inboundChildChannelInitializer: { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return childChannel.pipeline.addHandlers([
                    SSHCommandHandler(),
                    LegacyErrorHandler()
                ])
            }
        )
        return channel.pipeline.addHandler(sshHandler)
    }

    private func processError(_ error: Error) -> Error {
        let errorString = error.localizedDescription.lowercased()
        let errorTypeName = String(describing: type(of: error))

        if errorString.contains("nioconnectionerror") || errorTypeName.contains("NIOConnectionError") {
            if errorString.contains("connecttimeout") || errorString.contains("timeout") {
                return SSHError.timeout
            } else if errorString.contains("dnsaerror") || errorString.contains("dnsaaaerror") {
                return SSHError.connectionFailed("Could not find the device on your network")
            } else {
                return SSHError.connectionFailed("Network connection failed")
            }
        }

        if errorString.contains("network is unreachable") ||
           errorString.contains("host is unreachable") ||
           errorString.contains("no route to host") ||
           errorString.contains("connection timed out") {
            return SSHError.connectionFailed("Network connectivity lost")
        }

        if errorString.contains("dns") ||
           errorString.contains("unknown host") ||
           errorString.contains("nodename nor servname provided") {
            return SSHError.connectionFailed("Could not find the device on your network")
        }

        if errorString.contains("auth failed") || errorString.contains("permission denied") {
            return SSHError.authenticationFailed
        }

        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ECONNREFUSED: return SSHError.connectionFailed("Remote Login is not enabled")
            case .EHOSTUNREACH: return SSHError.connectionFailed("Computer is not reachable")
            case .ETIMEDOUT: return SSHError.timeout
            case .ENETUNREACH: return SSHError.connectionFailed("Network connectivity lost")
            case .ENOTCONN: return SSHError.connectionFailed("Connection was lost")
            default: return SSHError.connectionFailed("Network error: \(posixError.localizedDescription)")
            }
        }

        if errorString.contains("connection reset") ||
           errorString.contains("eof") ||
           errorString.contains("broken pipe") {
            return SSHError.connectionFailed("Connection was interrupted")
        }

        return SSHError.connectionFailed("Could not establish connection")
    }

    private func createSession(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let connection = connection else {
            completion(.failure(SSHError.channelNotConnected))
            return
        }

        let promise = connection.eventLoop.makePromise(of: Channel.self)
        connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler -> EventLoopFuture<Channel> in
            handler.createChannel(promise) { channel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return channel.pipeline.addHandlers([
                    SSHCommandHandler(),
                    LegacyErrorHandler()
                ])
            }
            return promise.futureResult
        }.whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                self?.session = channel
                completion(.success(()))
            case .failure(let error):
                completion(.failure(self?.processError(error) ?? error))
            }
        }
    }

    // MARK: - SSHClientProtocol

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
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("tcp shutdown") ||
                   errorString.contains("connection reset") ||
                   errorString.contains("broken pipe") ||
                   errorString.contains("connection closed") ||
                   errorString.contains("eof") {
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
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("eof") ||
                   errorString.contains("connection reset") ||
                   errorString.contains("broken pipe") ||
                   errorString.contains("connection closed") ||
                   errorString.contains("tcp shutdown") {
                    self.disconnect()
                    completion(.failure(SSHError.channelError("Connection lost")))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    func disconnect() {
        hasCompletedConnection = false

        if let session = session {
            let exitRequest = SSHChannelRequestEvent.ExecRequest(command: "exit", wantReply: false)
            _ = session.triggerUserOutboundEvent(exitRequest)
            session.pipeline.handler(type: SSHCommandHandler.self).whenSuccess { handler in
                handler.pendingCommandPromise?.fail(SSHError.channelError("Connection closed"))
            }
        }

        authDelegate = nil
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
