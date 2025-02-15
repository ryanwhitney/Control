import Foundation
import NIOSSH
import NIOCore
import NIOPosix

enum SSHError: Error {
    case channelNotConnected
    case invalidChannelType
    case authenticationFailed
    case connectionFailed(String)
    case timeout
    case channelError(String)
    case noSession
}

class SSHClient: SSHClientProtocol {
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
        // Reset connection state
        hasCompletedConnection = false
        
        // Only clean up if we have an active connection
        if connection != nil {
            disconnect()
        }
        
        // Set up timeout
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !self.hasCompletedConnection else { return }
            print("❌ Connection timed out")
            self.hasCompletedConnection = true
            self.disconnect()
            completion(.failure(SSHError.timeout))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)
        
        // Set up auth delegate
        let authDelegate = PasswordAuthDelegate(username: username, password: password)
        authDelegate.onAuthFailure = { [weak self] in
            guard let self = self, !self.hasCompletedConnection else { return }
            timeout.cancel()
            self.hasCompletedConnection = true
            self.disconnect()
            completion(.failure(SSHError.authenticationFailed))
        }
        self.authDelegate = authDelegate
        
        // Create and configure bootstrap
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { [weak self] channel in
                self?.setupChannel(channel, authDelegate: authDelegate) ?? channel.eventLoop.makeFailedFuture(SSHError.channelError("Failed to setup channel"))
            }
        
        // Attempt connection
        print("Connecting to \(host):22...")
        bootstrap.connect(host: host, port: 22).whenComplete { [weak self] result in
            timeout.cancel()
            
            switch result {
            case .success(let channel):
                if self?.hasCompletedConnection == false {
                    self?.connection = channel
                    self?.createSession { [weak self] sessionResult in
                        switch sessionResult {
                        case .success:
                            if self?.hasCompletedConnection == false {
                                timeout.cancel()
                                if authDelegate.authFailed {
                                    self?.hasCompletedConnection = true
                                    completion(.failure(SSHError.authenticationFailed))
                                } else {
                                    self?.hasCompletedConnection = true
                                    completion(.success(()))
                                }
                            }
                        case .failure(let error):
                            if self?.hasCompletedConnection == false {
                                timeout.cancel()
                                self?.hasCompletedConnection = true
                                completion(.failure(error))
                            }
                        }
                    }
                }
                
            case .failure(let error):
                if self?.hasCompletedConnection == false {
                    timeout.cancel()
                    self?.hasCompletedConnection = true
                    completion(.failure(error))
                }
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
                    ErrorHandler()
                ])
            }
        )
        return channel.pipeline.addHandler(sshHandler)
    }
    
    private func processError(_ error: Error) -> Error {
        let errorString = error.localizedDescription.lowercased()
        print("Processing error: \(errorString)")
        
        // Authentication failures
        if errorString.contains("auth failed") || 
           errorString.contains("permission denied") {
            return SSHError.authenticationFailed
        }
        
        // Connection failures
        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ECONNREFUSED:
                return SSHError.connectionFailed("Remote Login is not enabled")
            case .EHOSTUNREACH:
                return SSHError.connectionFailed("Computer is not reachable")
            case .ETIMEDOUT:
                return SSHError.timeout
            default:
                return SSHError.connectionFailed("Network error: \(posixError.localizedDescription)")
            }
        }
        
        // Connection reset and EOF are connection failures
        if errorString.contains("connection reset") ||
           errorString.contains("eof") ||
           errorString.contains("broken pipe") {
            return SSHError.connectionFailed("Connection was interrupted")
        }
        
        // If we get here, it's likely a connection issue
        return SSHError.connectionFailed("Could not establish connection")
    }
    
    private func createSession(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let connection = connection else {
            print("No active connection for session creation")
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        
        let promise = connection.eventLoop.makePromise(of: Channel.self)
        
        print("Creating SSH session...")
        connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler -> EventLoopFuture<Channel> in
            handler.createChannel(promise) { channel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return channel.pipeline.addHandlers([
                    SSHCommandHandler(),
                    ErrorHandler()
                ])
            }
            return promise.futureResult
        }.whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                print("✓ SSH session created")
                self?.session = channel
                completion(.success(()))
            case .failure(let error):
                print("SSH session creation failed: \(error)")
                completion(.failure(self?.processError(error) ?? error))
            }
        }
    }
    
    func executeCommand(_ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = session else {
            print("No active session")
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        
        print("$ \(description ?? "Running AppleScript command")")
        
        session.pipeline.handler(type: SSHCommandHandler.self).flatMap { handler -> EventLoopFuture<String> in
            let promise = session.eventLoop.makePromise(of: String.self)
            handler.pendingCommandPromise = promise
            
            let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            return session.triggerUserOutboundEvent(execRequest).flatMap { _ in
                return promise.futureResult
            }
        }.whenComplete { result in
            switch result {
            case .success(let output):
                completion(.success(output))
            case .failure(let error):
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("channel setup rejected") || errorString.contains("open failed") {
                    print("Channel setup was rejected by the server")
                    completion(.failure(SSHError.channelError("Server rejected channel setup")))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }
    
    func executeCommandWithNewChannel(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let connection = connection else {
            print("No active connection")
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        
        if let description = description {
            print("$ \(description)")
        }
        
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
                    ErrorHandler()
                ])
            }
            
            return childPromise.futureResult.map { channel in
                commandChannel = channel
                return channel
            }.flatMapError { error in
                print("Channel creation failed: \(error)")
                // Check for TCP shutdown and other fatal errors
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("tcp shutdown") ||
                   errorString.contains("connection reset") ||
                   errorString.contains("broken pipe") ||
                   errorString.contains("connection closed") ||
                   errorString.contains("eof") {
                    print("Fatal connection error detected: \(error)")
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
                    // Add timeout for command execution
                    channel.eventLoop.scheduleTask(in: .seconds(5)) {
                        if let pendingPromise = handler.pendingCommandPromise {
                            print("Command execution timed out")
                            pendingPromise.fail(SSHError.timeout)
                            channel.close(promise: nil)
                        }
                    }
                    return promise.futureResult
                }
            }
        }.whenComplete { result in
            // Clean up the channel
            if let channel = commandChannel {
                channel.close(promise: nil)
            }
            
            switch result {
            case .success(let output):
                if let description = description {
                    print("$ \(description)")
                }
                if !output.isEmpty {
                    print("Received output: \(output)")
                }
                completion(.success(output))
            case .failure(let error):
                print("SSH Error: \(error)")
                // Check if the error indicates a disconnection
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("eof") || 
                   errorString.contains("connection reset") ||
                   errorString.contains("broken pipe") ||
                   errorString.contains("connection closed") ||
                   errorString.contains("tcp shutdown") {
                    print("Connection appears to be closed - disconnecting")
                    self.disconnect()
                    completion(.failure(SSHError.channelError("Connection lost")))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }
    
    func disconnect() {
        print("\n=== SSHClient: Disconnecting ===")
        // Cancel any pending promises before closing channels
        if let session = session {
            session.pipeline.handler(type: SSHCommandHandler.self).whenSuccess { handler in
                if let promise = handler.pendingCommandPromise {
                    print("Cancelling pending command promise")
                    promise.fail(SSHError.channelError("Connection closed"))
                }
            }
        }
        
        session?.close(promise: nil)
        session = nil
        connection?.close(promise: nil)
        connection = nil
        print("✓ Disconnected and cleaned up resources")
    }
}

class SSHCommandHandler: ChannelInboundHandler {
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

class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var authAttempts = 0
    private(set) var authFailed = false
    var onAuthFailure: (() -> Void)?
    
    init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        authAttempts += 1
        
        // Only attempt password auth if it's available
        if !availableMethods.contains(.password) {
            print("Password authentication not available")
            authFailed = true
            onAuthFailure?()
            nextChallengePromise.succeed(nil)
            return
        }
        
        // Allow only one authentication attempt
        if authAttempts > 1 {
            print("Authentication failed after attempt")
            authFailed = true
            onAuthFailure?()
            nextChallengePromise.succeed(nil)
            return
        }
        
        print("Attempting password authentication")
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
        )
    }
}

class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

