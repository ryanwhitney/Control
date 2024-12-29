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
    typealias OutboundIn = SSHChannelRequestEvent

    private var pendingCommandPromise: EventLoopPromise<String>?
    private var buffer: String = ""
    private var isChannelActive = false

    func channelActive(context: ChannelHandlerContext) {
        isChannelActive = true
        context.fireChannelActive()
    }

    func sendCommand(_ command: String, on channel: Channel) -> EventLoopFuture<String> {
        let promise = channel.eventLoop.makePromise(of: String.self)
        
        guard isChannelActive else {
            promise.fail(SSHError.channelNotConnected)
            return promise.futureResult
        }
        
        pendingCommandPromise = promise

        print("Executing command: \(command)")
        
        guard let context = context else {
            promise.fail(SSHError.channelNotConnected)
            return promise.futureResult
        }

        // Convert command to channel data
        var buffer = channel.allocator.buffer(capacity: command.utf8.count)
        buffer.writeString(command)
        
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.writeAndFlush(wrapOutboundOut(channelData), promise: nil)

        return promise.futureResult
    }

    private var context: ChannelHandlerContext?
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let sshData = unwrapInboundIn(data)
        
        switch sshData.type {
        case .channel:
            guard case .byteBuffer(let buffer) = sshData.data else {
                print("Received non-buffer channel data")
                return
            }
            
            if let output = buffer.getString(at: 0, length: buffer.readableBytes) {
                print("Received output: '\(output)'")
                self.buffer += output
                
                if output.contains("\n") || buffer.readableBytes == 0 {
                    completeCommand()
                }
            } else {
                print("Could not get string from buffer")
            }
        case .stdErr:
            guard case .byteBuffer(let buffer) = sshData.data,
                  let errorOutput = buffer.getString(at: 0, length: buffer.readableBytes) else {
                print("Received non-buffer stderr data")
                return
            }
            print("Command stderr: '\(errorOutput)'")
            self.buffer += "[Error] " + errorOutput
            completeCommand()
        default:
            print("Received unknown channel data type: \(sshData.type)")
            break
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
        
        if !buffer.isEmpty {
            completeCommand()
        }
    }
    
    private func completeCommand() {
        if !buffer.isEmpty {
            let output = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            print("Completing command with output: \(output)")
            pendingCommandPromise?.succeed(output)
            pendingCommandPromise = nil
            buffer = ""
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        completeCommand()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Command handler error: \(error)")
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
