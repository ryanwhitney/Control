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

class SSHClient: SSHClientProtocol, @unchecked Sendable {
    private var group: EventLoopGroup
    private var connection: Channel?
    private var hasCompletedConnection = false
    
    // MARK: - Dedicated Channel Support
    // Using a single app channel improves stability by serialising all app commands
    private let appChannelPoolSize = 1
    
    /// Executors keyed by physical channel name (e.g. "system", "app-0", "app-1")
    private var dedicatedExecutors: [String: ChannelExecutor] = [:]
    
    /// Retrieve an existing executor or create a new one based on the logical key.
    /// This function maps a logical key (like "spotify") to a physical executor (like "app-2").
    private func executor(for key: String) async throws -> ChannelExecutor {
        let executorKey: String

        if key == "system" {
            executorKey = "system"
        } else if key == "heartbeat" {
            // Dedicated persistent channel for heartbeats
            executorKey = "heartbeat"
        } else {
            // This is an app, so we use the pool.
            // Using hashValue provides a stable distribution of apps to channels.
            let poolIndex = abs(key.hashValue) % appChannelPoolSize
            executorKey = "app-\(poolIndex)"
        }
        
        // Create a new executor if still missing (non-blocking; possible race creates extra but harmless)
        if let existing = dedicatedExecutors[executorKey] {
            return existing
        }
        
        // Ensure we have an active SSH TCP connection.
        guard let connection = self.connection else {
            sshLog("📡 SSHClient: ❌ No active connection for executor creation")
            throw SSHError.channelNotConnected
        }
        
        // Create a new ChannelExecutor for this physical key ("app-N" or "system")
        let executor = ChannelExecutor(connection: connection, channelKey: executorKey)
        dedicatedExecutors[executorKey] = executor
        sshLog("🔧 SSH: Channel '\(executorKey)' ready")
        return executor
    }
    
    /// Async helper that runs a command on a dedicated channel and returns the Result.
    private func performOnDedicatedChannel(_ channelKey: String, command: String, description: String?) async -> Result<String, Error> {
        do {
            let exec = try await executor(for: channelKey)
            let result = await exec.run(command: command, description: description)
            if case .failure(let error) = result {
                var shouldReset = false
                if case SSHError.timeout = error { shouldReset = true }
                if case SSHError.channelError = error { shouldReset = true }
                if shouldReset {
                    let physicalKey: String
                    if channelKey == "system" {
                        physicalKey = "system"
                    } else if channelKey == "heartbeat" {
                        physicalKey = "heartbeat"
                    } else {
                        physicalKey = "app-\(abs(channelKey.hashValue) % appChannelPoolSize)"
                    }
                    dedicatedExecutors.removeValue(forKey: physicalKey)
                    sshLog("📡 SSHClient: Removed executor for key '\(physicalKey)' due to error – will recreate on next use")
                }
            }
            return result
        } catch {
            sshLog("📡 SSHClient: ❌ Failed to get executor or run command: \(error)")
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
        
        let connectionId = String(UUID().uuidString.prefix(8))
        sshLog("🆔 [\(connectionId)] SSHClient: Connecting to \(host) as \(username)")
        
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
        
        // Create and configure bootstrap with explicit timeout
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(4)) // Shorter than our 5-second timeout
            .channelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: authDelegate,
                        serverAuthDelegate: AcceptAllHostKeysDelegate()
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { childChannel, channelType in
                        // This initializer is for channels opened by the SERVER.
                        // We are opening channels from the client side, so this can be minimal.
                        guard channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                        }
                        return childChannel.pipeline.addHandler(ErrorHandler())
                    }
                ))
            }
        
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
                // With client-side channels, we don't need to pre-create a main session.
                // The connection is ready to be used by ChannelExecutors.
                if authDelegate.authFailed {
                    sshLog("❌ [\(connectionId)] Authentication failed post-connection")
                    self.hasCompletedConnection = true
                    completion(.failure(SSHError.authenticationFailed))
                } else {
                    sshLog("✓ [\(connectionId)] SSH connection ready for channels")
                    self.hasCompletedConnection = true
                    completion(.success(()))
                }
                
            case .failure(let error):
                sshLog("❌ [\(connectionId)] TCP connection failed: \(error.localizedDescription)")
                self.hasCompletedConnection = true
                completion(.failure(self.processError(error)))
            }
        }
    }
    
    private func processError(_ error: Error) -> Error {
        let errorString = error.localizedDescription.lowercased()
        
        // Network connectivity issues
        if errorString.contains("network is unreachable") ||
           errorString.contains("host is unreachable") ||
           errorString.contains("no route to host") ||
           errorString.contains("connection timed out") {
            return SSHError.connectionFailed("Network connectivity lost")
        }
        
        // DNS resolution failures
        if errorString.contains("dns") || 
           errorString.contains("unknown host") ||
           errorString.contains("nodename nor servname provided") {
            return SSHError.connectionFailed("Could not find the device on your network")
        }
        
        // Connection refused (e.g., Remote Login disabled)
        if let posixError = error as? POSIXError, posixError.code == .ECONNREFUSED {
            return SSHError.connectionFailed("Remote Login is not enabled")
        }
        
        // If we get here, it's likely a generic connection issue
        sshLog("Error classified as: Generic connection failure: \(errorString)")
        return SSHError.connectionFailed("Could not establish connection")
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
        
        connection?.close(promise: nil)
        connection = nil
        sshLog("✓ SSHClient disconnected and cleaned up")
    }
}

class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
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
        // Only attempt password auth if it's available
        if !availableMethods.contains(.password) {
            sshLog("Password authentication not available on server")
            authFailed = true
            onAuthFailure?()
            nextChallengePromise.succeed(nil)
            return
        }
        
        sshLog("Attempting password authentication")
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
        // This handler is for server-initiated channels, which we don't expect.
        // Logging the error is sufficient.
        sshLog("SSH Error on server-initiated channel: \(error)")
        context.close(promise: nil)
    }
}

