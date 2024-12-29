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
                    inboundChildChannelInitializer: { childChannel, channelType in
                        guard channelType == .session else {
                            return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                        }
                        return childChannel.pipeline.addHandler(SSHCommandHandler())
                    }
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
        
        connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            let childPromise = connection.eventLoop.makePromise(of: Channel.self)
            
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

        print("$ \(command)")  // Print the actual command being sent
        
        // Get the existing command handler
        session.pipeline.handler(type: SSHCommandHandler.self).flatMap { handler -> EventLoopFuture<String> in
            // Set up the promise for this command
            handler.pendingCommandPromise = session.eventLoop.makePromise(of: String.self)
            
            // Send the exec request
            let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            return session.triggerUserOutboundEvent(execRequest).flatMap { _ in
                return handler.pendingCommandPromise!.futureResult
            }
        }.whenComplete { result in
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
    typealias OutboundIn = Never

    var pendingCommandPromise: EventLoopPromise<String>?
    private var buffer: String = ""

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
                completeCommand()
            }
            
        case .stdErr:
            guard case .byteBuffer(let buffer) = channelData.data,
                  let errorOutput = buffer.getString(at: 0, length: buffer.readableBytes) else {
                return
            }
            print("Received error: \(errorOutput)")
            self.buffer += "[Error] " + errorOutput
            completeCommand()
            
        default:
            break
        }
    }

    private func completeCommand() {
        if !buffer.isEmpty {
            let output = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingCommandPromise?.succeed(output)
            pendingCommandPromise = nil
            buffer = ""
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("SSH Error: \(error)")
        pendingCommandPromise?.fail(error)
        pendingCommandPromise = nil
        buffer = ""
        context.close(promise: nil)
    }
}

enum SSHError: Error {
    case channelNotConnected
    case invalidChannelType
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
        context.close(promise: nil)
    }
}
