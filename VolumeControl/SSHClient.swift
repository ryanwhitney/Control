import Foundation
import NIOSSH
import NIOCore
import NIOPosix

class SSHClient {
    private var group: EventLoopGroup
    private var connection: Channel?
    private var session: Channel?

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
        print("Attempting to connect to \(host):\(port) with username: \(username)")
        
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                print("Initializing channel...")
                let sshHandler = NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: PasswordAuthDelegate(username: username, password: password),
                        serverAuthDelegate: AcceptAllHostKeysDelegate()
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(sshHandler)
            }

        print("Starting connection...")
        bootstrap.connect(host: host, port: port).whenComplete { result in
            switch result {
            case .failure(let error):
                print("Connection failed: \(error)")
                completion(.failure(error))
            case .success(let channel):
                print("Connection successful!")
                self.connection = channel
                
                // After connection, create a session
                self.createSession { result in
                    switch result {
                    case .success:
                        completion(.success(()))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    private func createSession(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let connection = connection else {
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        
        print("Creating SSH session...")
        
        connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let childPromise = connection.eventLoop.makePromise(of: Channel.self)
            
            sshHandler.createChannel(childPromise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                
                return childChannel.pipeline.addHandlers([
                    SSHCommandHandler(),
                    ErrorHandler()
                ])
            }
            
            return childPromise.futureResult
        }.whenComplete { result in
            switch result {
            case .success(let channel):
                print("Session created successfully")
                self.session = channel
                completion(.success(()))
            case .failure(let error):
                print("Session creation failed: \(error)")
                completion(.failure(error))
            }
        }
    }

    func executeCommand(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = session else {
            print("No active session")
            completion(.failure(SSHError.channelNotConnected))
            return
        }

        print("Executing command: \(command)")
        session.pipeline.handler(type: SSHCommandHandler.self).flatMap { handler in
            handler.sendCommand(command, on: session)
        }.whenComplete { result in
            switch result {
            case .success(let output):
                print("Command output: \(output)")
            case .failure(let error):
                print("Command failed: \(error)")
            }
            completion(result)
        }
    }
}

class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password) else {
            nextChallengePromise.succeed(nil)
            return
        }
        
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

    private var pendingCommandPromise: EventLoopPromise<String>?
    private var buffer: String = ""

    func sendCommand(_ command: String, on channel: Channel) -> EventLoopFuture<String> {
        let promise = channel.eventLoop.makePromise(of: String.self)
        pendingCommandPromise = promise

        // Use login shell with proper environment setup
        let wrappedCommand = """
        /bin/bash -l -c 'export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"; \
        export LANG="en_US.UTF-8"; \
        \(command)'
        """
        
        print("Executing wrapped command: \(wrappedCommand)")
        
        // Convert command to channel data
        let commandBuffer = channel.allocator.buffer(string: wrappedCommand)
        let commandData = SSHChannelData(type: .channel, data: .byteBuffer(commandBuffer))
        
        channel.writeAndFlush(commandData).whenFailure { error in
            promise.fail(error)
        }

        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let sshData = unwrapInboundIn(data)
        
        switch sshData.type {
        case .channel:
            guard case .byteBuffer(let buffer) = sshData.data else {
                return
            }
            
            if let output = buffer.getString(at: 0, length: buffer.readableBytes) {
                self.buffer += output
                completeCommand()
            }
        case .stdErr:
            guard case .byteBuffer(let buffer) = sshData.data,
                  let errorOutput = buffer.getString(at: 0, length: buffer.readableBytes) else {
                return
            }
            print("Command stderr: \(errorOutput)")
            self.buffer += "[Error] " + errorOutput
        default:
            break
        }
    }
    
    private func completeCommand() {
        if !buffer.isEmpty {
            pendingCommandPromise?.succeed(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            pendingCommandPromise = nil
            buffer = ""
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        completeCommand()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        pendingCommandPromise?.fail(error)
        pendingCommandPromise = nil
        buffer = ""
        
        // Close the channel on error
        context.close(promise: nil)
    }
}

enum SSHError: Error {
    case channelNotConnected
    case invalidChannelType
}

class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // WARNING: This accepts all host keys without verification
        // In a production environment, you should properly verify host keys
        validationCompletePromise.succeed(())
    }
}

// Add this helper class for error handling
private class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("SSH Error: \(error)")
        context.close(promise: nil)
    }
}
