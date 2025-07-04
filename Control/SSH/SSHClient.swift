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

// Concurrency limiter for simultaneous SSH channels
actor ChannelLimiter {
    private let maxConcurrent: Int
    private var current: Int = 0
    init(max: Int) { self.maxConcurrent = max }
    func acquire() async {
        while current >= maxConcurrent {
            await Task.yield()
        }
        current += 1
    }
    func release() {
        current = max(0, current - 1)
    }
}

// Shared global limiter – tweak `max` if the server allows more channels
private let sshChannelLimiter = ChannelLimiter(max: 4)

class SSHClient: SSHClientProtocol, @unchecked Sendable {
    private var group: EventLoopGroup
    private var connection: Channel?
    private var session: Channel?
    private var authDelegate: PasswordAuthDelegate?
    private var hasCompletedConnection = false
    
    // Adaptive timeout rolling averages keyed by command description
    private static var commandAverages: [String: Double] = [:]
    
    // MARK: - Dedicated Channel Support
    /// Executors keyed by logical channel name (e.g. "system", "music", etc.)
    private var dedicatedExecutors: [String: ChannelExecutor] = [:]
    
    /// Retrieve an existing executor for `key` or create a new one if necessary.
    private func executor(for key: String) async throws -> ChannelExecutor {
        if let existing = dedicatedExecutors[key] {
            return existing
        }
        
        // Ensure we have an active SSH TCP connection.
        guard let connection = self.connection else {
            throw SSHError.channelNotConnected
        }
        
        // Create a single ChannelExecutor which will internally open its own interactive shell.
        let executor = ChannelExecutor(connection: connection)
        dedicatedExecutors[key] = executor
        return executor
    }
    
    /// Async helper that runs a command on a dedicated channel and returns the Result.
    private func performOnDedicatedChannel(_ channelKey: String, command: String, description: String?) async -> Result<String, Error> {
        do {
            let exec = try await executor(for: channelKey)
            return await exec.run(command: command, description: description)
        } catch {
            return .failure(error)
        }
    }
    
    // Protocol-facing entry point (completion-handler style)
    func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            let result = await performOnDedicatedChannel(channelKey, command: command, description: description)
            completion(result)
        }
    }
    
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
        
        let connectionId = UUID().uuidString.prefix(8)
        sshLog("🆔 [\(connectionId)] SSHClient: Starting connection process")
        sshLog("Host: \(host.prefix(10))***")
        sshLog("Username: \(username.prefix(3))***")
        
        // Only clean up if we have an active connection
        if connection != nil {
            sshLog("Cleaning up existing connection before reconnecting")
            disconnect()
        }
        
        // Set up timeout
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !self.hasCompletedConnection else { return }
            sshLog("❌ [\(connectionId)] Connection timed out after 5 seconds")
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
            sshLog("❌ [\(connectionId)] Authentication failed")
            self.hasCompletedConnection = true
            self.disconnect()
            completion(.failure(SSHError.authenticationFailed))
        }
        self.authDelegate = authDelegate
        
        // Create and configure bootstrap with explicit timeout
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(4)) // Shorter than our 5-second timeout
            .channelInitializer { [weak self] channel in
                self?.setupChannel(channel, authDelegate: authDelegate) ?? channel.eventLoop.makeFailedFuture(SSHError.channelError("Failed to setup channel"))
            }
        
        // Attempt connection
        let isLocal = host.contains(".local")
        let connectionType = isLocal ? "SSH over Bonjour (.local)" : "SSH over TCP/IP"
        let hostRedacted = String(host.prefix(3)) + "***"
        
        sshLog("Attempting TCP connection: \(connectionType)")
        sshLog("Target: \(hostRedacted):22")
        
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
                self.createSession { [weak self] sessionResult in
                    guard let self = self, !self.hasCompletedConnection else { 
                        sshLog("⚠️ [\(connectionId)] Session creation completed but already handled, ignoring result")
                        return 
                    }
                    
                    switch sessionResult {
                    case .success:
                        if authDelegate.authFailed {
                            sshLog("❌ [\(connectionId)] Authentication failed during session creation")
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
                
                // Use centralized error processing (handles NIOConnectionError and timeouts)
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
                    ErrorHandler()
                ])
            }
        )
        return channel.pipeline.addHandler(sshHandler)
    }
    
    private func processError(_ error: Error) -> Error {
        let errorString = error.localizedDescription.lowercased()
        let errorTypeName = String(describing: type(of: error))
        sshLog("Processing SSH error: \(errorString)")
        sshLog("Error type: \(errorTypeName)")
        
        // Handle NIOConnectionError specifically
        if errorString.contains("nioconnectionerror") || errorTypeName.contains("NIOConnectionError") {
            sshLog("Error classified as: NIO connection error")
            
            // Check for timeout specifically in NIOConnectionError
            if errorString.contains("connecttimeout") || errorString.contains("timeout") {
                sshLog("NIOConnectionError contains timeout - converting to SSHError.timeout")
                return SSHError.timeout
            } else if errorString.contains("dnsaerror") || errorString.contains("dnsaaaerror") {
                sshLog("DNS resolution failed")
                return SSHError.connectionFailed("Could not find the device on your network")
            } else {
                sshLog("Generic NIOConnectionError - treating as network connection failed")
                return SSHError.connectionFailed("Network connection failed")
            }
        }
        
        // Network connectivity issues
        if errorString.contains("network is unreachable") ||
           errorString.contains("host is unreachable") ||
           errorString.contains("no route to host") ||
           errorString.contains("connection timed out") {
            sshLog("Error classified as: Network connectivity issue")
            return SSHError.connectionFailed("Network connectivity lost")
        }
        
        // DNS resolution failures
        if errorString.contains("dns") || 
           errorString.contains("unknown host") ||
           errorString.contains("nodename nor servname provided") {
            sshLog("Error classified as: DNS resolution failure")
            return SSHError.connectionFailed("Could not find the device on your network")
        }
        
        // Authentication failures
        if errorString.contains("auth failed") || 
           errorString.contains("permission denied") {
            sshLog("Error classified as: Authentication failure")
            return SSHError.authenticationFailed
        }
        
        // Connection failures
        if let posixError = error as? POSIXError {
            sshLog("POSIX error detected: \(posixError.code)")
            switch posixError.code {
            case .ECONNREFUSED:
                sshLog("Error classified as: Connection refused (Remote Login disabled)")
                return SSHError.connectionFailed("Remote Login is not enabled")
            case .EHOSTUNREACH:
                sshLog("Error classified as: Host unreachable")
                return SSHError.connectionFailed("Computer is not reachable")
            case .ETIMEDOUT:
                sshLog("Error classified as: Timeout")
                return SSHError.timeout
            case .ENETUNREACH:
                sshLog("Error classified as: Network unreachable")
                return SSHError.connectionFailed("Network connectivity lost")
            case .ENOTCONN:
                sshLog("Error classified as: Not connected")
                return SSHError.connectionFailed("Connection was lost")
            default:
                sshLog("Error classified as: Network error (\(posixError.code))")
                return SSHError.connectionFailed("Network error: \(posixError.localizedDescription)")
            }
        }
        
        // Connection reset and EOF are connection failures
        if errorString.contains("connection reset") ||
           errorString.contains("eof") ||
           errorString.contains("broken pipe") {
            sshLog("Error classified as: Connection interrupted")
            return SSHError.connectionFailed("Connection was interrupted")
        }
        
        // If we get here, it's likely a connection issue
        sshLog("Error classified as: Generic connection failure")
        return SSHError.connectionFailed("Could not establish connection")
    }
    
    private func createSession(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let connection = connection else {
            sshLog("❌ No active connection for session creation")
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        
        let promise = connection.eventLoop.makePromise(of: Channel.self)
        
        sshLog("Creating SSH session...")
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
                sshLog("✓ SSH session created successfully")
                self?.session = channel
                completion(.success(()))
            case .failure(let error):
                sshLog("❌ SSH session creation failed: \(error)")
                completion(.failure(self?.processError(error) ?? error))
            }
            
            // (Adaptive timeout not tracked for session creation)
        }
    }
    
    func executeCommand(_ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = session else {
            sshLog("❌ No active session for command execution")
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        
        let commandDesc = description ?? "Running AppleScript command"
        sshLog("Executing: \(commandDesc)")
        
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
                sshLog("✓ Command completed successfully")
                if !output.isEmpty {
                    sshLog("Command output: \(output)")
                }
                completion(.success(output))
            case .failure(let error):
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("channel setup rejected") || errorString.contains("open failed") {
                    sshLog("❌ Command failed: Server rejected channel setup")
                    completion(.failure(SSHError.channelError("Server rejected channel setup")))
                } else {
                    sshLog("❌ Command failed: \(error)")
                    completion(.failure(error))
                }
            }
        }
    }
    
    func executeCommandWithNewChannel(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        // Gate concurrent channel creations so we don't exceed the server's limit
        Task {
            await sshChannelLimiter.acquire()
            executeCommandDirectly(command, description: description) { result in
                completion(result)
                // Release permit after command is done
                Task { await sshChannelLimiter.release() }
            }
        }
    }
    
    /// Execute command directly without heartbeat checks - used by the heartbeat mechanism itself
    func executeCommandBypassingHeartbeat(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        // Heartbeats can be triggered in parallel from different contexts. Protect the server's
        // channel limit by acquiring a permit from the shared limiter before opening a new
        // exec-style channel.
        Task {
            await sshChannelLimiter.acquire()
            executeCommandDirectly(command, description: description) { result in
                completion(result)
                // Always release the permit when the command completes.
                Task { await sshChannelLimiter.release() }
            }
        }
    }
    
    /// Direct execution method that bypasses heartbeat checks (used by heartbeat itself)
    private func executeCommandDirectly(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let connection = connection else {
            sshLog("❌ No active connection for new channel command")
            completion(.failure(SSHError.channelNotConnected))
            return
        }
        
        let commandDesc = description ?? "Running command with new channel"
        sshLog("Executing with new channel: \(commandDesc)")
        
        let childPromise = connection.eventLoop.makePromise(of: Channel.self)
        var commandChannel: Channel?
        
        let start = Date() // track duration for adaptive timeout updates
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
                sshLog("❌ Channel creation failed: \(error)")
                // Check for TCP shutdown and other fatal errors
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("tcp shutdown") ||
                   errorString.contains("connection reset") ||
                   errorString.contains("broken pipe") ||
                   errorString.contains("connection closed") ||
                   errorString.contains("eof") {
                    sshLog("🚨 Fatal connection error detected - connection lost")
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
                    // Adaptive timeout: rolling average * 3, min 2, max 8
                    let key = commandDesc.prefix(40).description
                    let average = SSHClient.commandAverages[key] ?? 0.5
                    var timeoutSeconds = max(average * 3.0, command.contains("set volume") ? 1.5 : 2.0)
                    timeoutSeconds = min(timeoutSeconds, 8.0)
                    if command.contains("heartbeat-") { timeoutSeconds = 3 }
                    channel.eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
                        if let pendingPromise = handler.pendingCommandPromise {
                            sshLog("⏰ Command execution timed out after \(timeoutSeconds) seconds")
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
                sshLog("✓ New channel command completed successfully")
                if !output.isEmpty {
                    sshLog("Command output: \(output)")
                }
                completion(.success(output))
            case .failure(let error):
                sshLog("❌ New channel command failed: \(error)")
                // Check if the error indicates a disconnection
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("eof") || 
                   errorString.contains("connection reset") ||
                   errorString.contains("broken pipe") ||
                   errorString.contains("connection closed") ||
                   errorString.contains("tcp shutdown") {
                    sshLog("🚨 Connection appears to be closed - cleaning up")
                    self.disconnect()
                    completion(.failure(SSHError.channelError("Connection lost")))
                } else {
                    completion(.failure(error))
                }
            }
            
            // Update rolling average on success
            if case .success = result {
                let duration = Date().timeIntervalSince(start)
                let key = commandDesc.prefix(40).description
                let prev = SSHClient.commandAverages[key] ?? duration
                SSHClient.commandAverages[key] = prev * 0.7 + duration * 0.3
            }
        }
    }
    
    func disconnect() {
        sshLog("SSHClient: Starting disconnect process")
        
        // Reset connection completion state
        hasCompletedConnection = false
        
        // Close and clear any dedicated channels
        for (key, executor) in dedicatedExecutors {
            sshLog("Closing dedicated channel for key: \(key)")
            Task { await executor.close() }
        }
        dedicatedExecutors.removeAll()
        
        // Send exit command to gracefully close remote session if possible
        if let session = session {
            sshLog("Sending exit command to gracefully close remote session")
            let exitPromise = session.eventLoop.makePromise(of: Void.self)
            let exitRequest = SSHChannelRequestEvent.ExecRequest(command: "exit", wantReply: false)
            session.triggerUserOutboundEvent(exitRequest).whenComplete { _ in
                exitPromise.succeed(())
            }
            
            // Don't wait too long for exit command
            session.eventLoop.scheduleTask(in: .milliseconds(500)) {
                exitPromise.succeed(())
            }
            
            // Cancel any pending promises after exit attempt
            session.pipeline.handler(type: SSHCommandHandler.self).whenSuccess { handler in
                if let promise = handler.pendingCommandPromise {
                    sshLog("Cancelling pending command promise")
                    promise.fail(SSHError.channelError("Connection closed"))
                }
            }
        }
        
        // Clean up auth delegate
        authDelegate = nil
        
        // Close session and connection
        session?.close(promise: nil)
        session = nil
        connection?.close(promise: nil)
        connection = nil
        sshLog("✓ SSHClient disconnected and cleaned up")
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
            if hasReceivedOutput {
                promise.fail(SSHError.channelError("Connection closed"))
            } else {
                // No output received but channel closed cleanly – treat as success with empty output
                promise.succeed("")
            }
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

