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
}

class SSHClient {
    private var group: EventLoopGroup
    private var connection: Channel?
    private var session: Channel?
    private var authDelegate: PasswordAuthDelegate?

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    func connect(
        host: String,
        port: Int = 22,
        username: String,
        password: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Add a master timeout that cannot be cancelled
        var hasCompleted = false
        let masterTimeout = DispatchWorkItem {
            guard !hasCompleted else { return }
            hasCompleted = true
            print("❌ Master timeout triggered - forcing disconnect")
            self.disconnect()
            completion(.failure(SSHError.timeout))
        }
        
        // Master timeout of 5 seconds, no exceptions
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: masterTimeout)
        
        let wrappedCompletion: (Result<Void, Error>) -> Void = { result in
            guard !hasCompleted else { return }
            hasCompleted = true
            masterTimeout.cancel()
            completion(result)
        }

        print("\n=== SSH Connection Details ===")
        print("Target: \(host):\(port)")
        print("Username: \(username)")
        print("Password length: \(password.count)")
        
        let authDelegate = PasswordAuthDelegate(username: username, password: password)
        // Set up immediate auth failure callback
        authDelegate.onAuthFailure = { [weak self] in
            print("❌ Authentication failed immediately")
            self?.disconnect()
            wrappedCompletion(.failure(SSHError.authenticationFailed))
        }
        self.authDelegate = authDelegate
        
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                print("Initializing SSH channel...")
                let sshHandler = NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: authDelegate,
                        serverAuthDelegate: AcceptAllHostKeysDelegate()
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { childChannel, channelType in
                        guard channelType == .session else {
                            print("❌ Invalid channel type: \(channelType)")
                            return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                        }
                        print("✓ Channel type valid: \(channelType)")
                        let commandHandler = SSHCommandHandler()
                        return childChannel.pipeline.addHandlers([
                            commandHandler,
                            ErrorHandler()
                        ])
                    }
                )
                
                return channel.pipeline.addHandler(sshHandler)
            }

        print("\nAttempting connection...")
        
        bootstrap.connect(host: host, port: port).whenComplete { result in
            switch result {
            case .failure(let error):
                print("❌ Connection failed")
                print("Error details: \(error)")
                
                // Handle DNS and connection errors specifically
                if error is NIOConnectionError {
                    wrappedCompletion(.failure(SSHError.connectionFailed("Could not find the computer on the network")))
                } else {
                    let errorMessage = self.interpretConnectionError(error)
                    wrappedCompletion(.failure(SSHError.connectionFailed(errorMessage)))
                }
                
            case .success(let channel):
                print("✓ TCP connection established")
                self.connection = channel
                
                self.createSession { result in
                    switch result {
                    case .success:
                        if let authDelegate = self.authDelegate, authDelegate.authFailed {
                            print("❌ Authentication failed after session creation attempt")
                            self.disconnect()
                            wrappedCompletion(.failure(SSHError.authenticationFailed))
                        } else {
                            print("✓ SSH session established")
                            wrappedCompletion(.success(()))
                        }
                    case .failure(let error):
                        if let sshError = error as? SSHError {
                            wrappedCompletion(.failure(sshError))
                        } else {
                            // Check for common auth failure indicators
                            let errorString = error.localizedDescription.lowercased()
                            if errorString.contains("eof") || 
                               errorString.contains("connection reset") ||
                               errorString.contains("shutdown") {
                                print("❌ Connection terminated (likely due to authentication failure)")
                                wrappedCompletion(.failure(SSHError.authenticationFailed))
                            } else {
                                wrappedCompletion(.failure(SSHError.channelError(error.localizedDescription)))
                            }
                        }
                        self.disconnect()
                    }
                }
            }
        }
    }
    
    private func interpretConnectionError(_ error: Error) -> String {
        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ECONNREFUSED:
                return "Remote Login is not enabled on this computer"
            case .EHOSTUNREACH:
                return "Computer is not reachable on the network"
            case .ETIMEDOUT:
                return "Connection timed out - check network connection and firewall settings"
            default:
                return "Network error: \(posixError.localizedDescription)"
            }
        }
        return "Could not establish a connection to the computer"
    }
    
    private func createSession(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let connection = connection else {
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        
        print("Creating SSH session...")
        
        let childPromise = connection.eventLoop.makePromise(of: Channel.self)
        
        connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            sshHandler.createChannel(childPromise) { (childChannel: Channel, channelType: SSHChannelType) -> EventLoopFuture<Void> in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                
                let commandHandler = SSHCommandHandler()
                return childChannel.pipeline.addHandlers([
                    commandHandler,
                    ErrorHandler()
                ])
            }
            
            return childPromise.futureResult.flatMapError { error in
                print("Channel creation failed: \(error)")
                // If we get EOF during session creation and auth failed, it's an auth error
                if error.localizedDescription.lowercased().contains("eof"),
                   let authDelegate = self.authDelegate,
                   authDelegate.authFailed {
                    return connection.eventLoop.makeFailedFuture(SSHError.authenticationFailed)
                }
                return connection.eventLoop.makeFailedFuture(error)
            }
        }.whenComplete { result in
            switch result {
            case .success(let channel):
                print("Session created successfully")
                self.session = channel
                completion(.success(()))
            case .failure(let error):
                print("Session creation failed: \(error)")
                // If we get EOF during session creation and auth failed, it's an auth error
                if error.localizedDescription.lowercased().contains("eof"),
                   let authDelegate = self.authDelegate,
                   authDelegate.authFailed {
                    completion(.failure(SSHError.authenticationFailed))
                } else if error.localizedDescription.lowercased().contains("channel setup rejected") || 
                          error.localizedDescription.lowercased().contains("open failed") {
                    print("Channel setup was rejected by the server")
                    completion(.failure(SSHError.channelError("Server rejected channel setup")))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    func executeCommand(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = session else {
            print("No active session")
            completion(.failure(SSHError.channelNotConnected))
            return
        }

        print("$ \(command)")

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

    // New method for subsequent commands
    func executeCommandWithNewChannel(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let connection = connection else {
            print("No active session")
            completion(.failure(SSHError.channelNotConnected))
            return
        }

        print("$ \(command)")
        
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
                childPromise.fail(error)  // Ensure promise is completed
                return connection.eventLoop.makeFailedFuture(error)
            }
        }.flatMap { channel -> EventLoopFuture<String> in
            channel.pipeline.handler(type: SSHCommandHandler.self).flatMap { handler in
                guard let promise = handler.pendingCommandPromise else {
                    return channel.eventLoop.makeFailedFuture(SSHError.channelError("Command promise not set"))
                }
                
                let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
                return channel.triggerUserOutboundEvent(execRequest).flatMap { _ in
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

    func disconnect() {
        session?.close(promise: nil)
        session = nil
        connection?.close(promise: nil)
        connection = nil
    }
}

class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var _authFailed = false
    private var authAttempts = 0
    var onAuthFailure: (() -> Void)?
    
    var authFailed: Bool { _authFailed }

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        authAttempts += 1
        
        // If we're called more than once, it means previous attempts failed
        if authAttempts > 1 {
            print("❌ Authentication attempt #\(authAttempts) - previous attempt failed")
            _authFailed = true
            onAuthFailure?()
            nextChallengePromise.succeed(nil)
            return
        }
        
        guard availableMethods.contains(.password) else {
            print("❌ Password authentication not available")
            _authFailed = true
            onAuthFailure?()
            nextChallengePromise.succeed(nil)
            return
        }
        
        print("Attempting password authentication...")
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .password(.init(password: password))
        )
        nextChallengePromise.succeed(offer)
    }
}

class SSHCommandHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    typealias OutboundIn = Never

    var pendingCommandPromise: EventLoopPromise<String>?
    private var buffer: String = ""
    private var isExecutingCommand = false
    private var hasReceivedOutput = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        
        switch channelData.type {
        case .channel:
            guard case .byteBuffer(let buffer) = channelData.data else {
                return
            }
            
            if let output = buffer.getString(at: 0, length: buffer.readableBytes) {
                print("Received output: \(output)")
                self.buffer += output
                hasReceivedOutput = true
                
                // Only complete if we've received actual output
                if !output.isEmpty {
                    completeCommand()
                }
            }
            
        case .stdErr:
            guard case .byteBuffer(let buffer) = channelData.data,
                  let errorOutput = buffer.getString(at: 0, length: buffer.readableBytes) else {
                return
            }
            print("Received error: \(errorOutput)")
            self.buffer += "[Error] " + errorOutput
            hasReceivedOutput = true
            completeCommand()
            
        default:
            break
        }
    }

    private func completeCommand() {
        if hasReceivedOutput {
            let output = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingCommandPromise?.succeed(output)
            pendingCommandPromise = nil
            buffer = ""
            isExecutingCommand = false
            hasReceivedOutput = false
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // If the channel closes before we complete, ensure we complete the promise
        if let promise = pendingCommandPromise {
            if !buffer.isEmpty {
                promise.succeed(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                promise.fail(SSHError.channelError("Channel closed before receiving output"))
            }
            pendingCommandPromise = nil
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("SSH Error: \(error)")
        // Ensure promise is completed on error
        pendingCommandPromise?.fail(error)
        pendingCommandPromise = nil
        context.close(promise: nil)
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
        print("SSH Error: \(error)")
        let errorString = error.localizedDescription.lowercased()
        if errorString.contains("shutdown") || errorString.contains("eof") {
            print("❌ Connection terminated (likely due to authentication failure)")
        }
        context.close(promise: nil)
    }
}
