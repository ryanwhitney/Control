import Foundation
import SwiftUI

@MainActor
class SSHConnectionManager: ObservableObject, SSHClientProtocol {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    private nonisolated let sshClient: SSHClient
    private var currentCredentials: Credentials?
    private var connectionLostHandler: (@MainActor () -> Void)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    static let shared = SSHConnectionManager()
    
    struct Credentials: Equatable {
        let host: String
        let username: String
        let password: String
    }
    
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
        
        var description: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .failed(let error): return "failed(\(error))"
            }
        }
    }
    
    init() {
        connectionLog("SSHConnectionManager: Initializing")
        self.sshClient = SSHClient()
    }
    
    func setConnectionLostHandler(_ handler: @escaping @MainActor () -> Void) {
        self.connectionLostHandler = handler
    }
    
    nonisolated var client: SSHClient { 
        sshLog("SSHConnectionManager: Accessing SSH client")
        return sshClient 
    }
    
    func handleConnectionLost() {
        sshLog("🚨 SSHConnectionManager: Connection Lost Detected")
        Task { @MainActor in
            let previousState = connectionState.description
            connectionState = .disconnected
            sshLog("Connection state changed: \(previousState) -> \(connectionState.description)")
            sshLog("🚨 Triggering connection lost handler to update UI")
            disconnect()
            connectionLostHandler?()
        }
    }
    
    func connect(host: String, username: String, password: String) async throws {
        connectionLog("SSHConnectionManager: Connection Request")
        
        // Show connection metadata without exposing sensitive info
        let isLocal = host.contains(".local")
        let connectionType = isLocal ? "Bonjour (.local)" : "TCP/IP"
        let hostRedacted = String(host.prefix(3)) + "***"
        
        connectionLog("Connecting via \(connectionType) to \(hostRedacted)")
        
        // Always clean up first to prevent state corruption
        await cleanupExistingConnection()
        
        connectionState = .connecting
        currentCredentials = Credentials(host: host, username: username, password: password)
        
        return try await withCheckedThrowingContinuation { continuation in
            let client = self.client // Capture nonisolated client
            var hasResumed = false
            let connectionId = UUID().uuidString.prefix(8)
            
            client.connect(host: host, username: username, password: password) { result in
                Task { @MainActor in
                    guard !hasResumed else {
                        connectionLog("⚠️ [\(connectionId)] Continuation already resumed, ignoring duplicate result: \(result)")
                        return
                    }
                    hasResumed = true
                    connectionLog("🔄 [\(connectionId)] Processing connection result: \(result)")
                    
                    switch result {
                    case .success:
                        connectionLog("✓ [\(connectionId)] Connection successful")
                        self.connectionState = .connected
                        continuation.resume()
                    case .failure(let error):
                        connectionLog("❌ [\(connectionId)] Connection failed: \(error)")
                        self.connectionState = .failed(error.localizedDescription)
                        self.currentCredentials = nil
                        
                        // Ensure client is disconnected on failure to prevent stale state
                        client.disconnect()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    func verifyConnection(host: String, username: String, password: String) async throws {
        try await connect(host: host, username: username, password: password)
    }
    
    private func cleanupExistingConnection() async {
        disconnect()
        // Give a small delay to ensure cleanup
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
    }
    
    nonisolated func disconnect() {
        sshClient.disconnect()
        Task { @MainActor in
            self.connectionState = .disconnected
            self.currentCredentials = nil
        }
    }
    
    deinit {
        sshClient.disconnect()
    }
    
    func shouldReconnect(host: String, username: String, password: String) -> Bool {
        guard case .connected = connectionState else { 
            return true 
        }
        
        // Check if we're already connected with the same credentials
        if let existing = currentCredentials,
           existing.host == host,
           existing.username == username,
           existing.password == password {
            connectionLog("✓ Using existing connection")
            return false
        }
        
        return true
    }
    
    // MARK: - Lifecycle Management
    
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        connectionLog("Scene phase: \(oldPhase) -> \(newPhase)")
        
        switch newPhase {
        case .active:
            endBackgroundTask()
        case .inactive:
            // No action needed, keep connection alive
            break
        case .background:
            startBackgroundTask()
        @unknown default:
            connectionLog("Unknown scene phase: \(newPhase)")
        }
    }
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Background task is about to expire, disconnect gracefully
            self?.client.disconnect() // Use direct client disconnect for graceful exit
            self?.disconnect() // Then update our state
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    /// Shared connection handler that manages common connection logic
    func handleConnection(
        host: String,
        username: String,
        password: String,
        onSuccess: @escaping () async -> Void,
        onError: @escaping (Error) -> Void
    ) {
        Task {
            do {
                if !shouldReconnect(host: host, username: username, password: password) {
                    await onSuccess()
                    return
                }
                
                try await connect(host: host, username: username, password: password)
                await onSuccess()
            } catch {
                onError(error)
            }
        }
    }
    
    // Centralized connection loss detection
    nonisolated func isConnectionLossError(_ error: Error) -> Bool {
        let errorString = error.localizedDescription.lowercased()
        let isConnectionLoss = errorString.contains("connection lost") ||
               errorString.contains("eof") ||
               errorString.contains("connection reset") ||
               errorString.contains("broken pipe") ||
               errorString.contains("connection closed") ||
               errorString.contains("tcp shutdown") ||
               errorString.contains("network is unreachable") ||
               errorString.contains("host is unreachable") ||
               errorString.contains("connection timed out") ||
               errorString.contains("no route to host")
        
        if isConnectionLoss {
            sshLog("🚨 Connection loss detected: \(errorString)")
        }
        
        return isConnectionLoss
    }
    
    /// Execute a command with post-command heartbeat verification
    /// 
    /// This method now includes a heartbeat mechanism that:
    /// - Executes the user command normally
    /// - Sends a heartbeat after the command to verify connection health
    /// - Triggers reconnection if heartbeat fails within 3 seconds
    /// - Prevents hard crashes by detecting dead connections quickly
    nonisolated func executeCommandWithNewChannel(_ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        sshLog("SSHConnectionManager: Executing command via new channel")
        if let description = description {
            sshLog("Command: \(description)")
        }
        
        // Execute the command normally
        client.executeCommandWithNewChannel(command, description: description) { [weak self] result in
            switch result {
            case .success(_):
                sshLog("✓ Command completed successfully")
                // Send post-command heartbeat to verify connection health
                self?.executePostCommandHeartbeat()
                completion(result)
            case .failure(let error):
                sshLog("❌ Command failed: \(error)")
                if self?.isConnectionLossError(error) == true {
                    sshLog("🚨 Connection loss detected during command execution")
                    Task { @MainActor [weak self] in
                        self?.handleConnectionLost()
                    }
                } else {
                    // Send heartbeat after failed command to check if connection is still alive
                    self?.executePostCommandHeartbeat()
                }
                completion(result)
            }
        }
    }
    
    /// Executes a post-command heartbeat to verify connection is still alive
    /// If heartbeat fails within 3 seconds, triggers reconnection
    nonisolated private func executePostCommandHeartbeat() {
        let heartbeatCommand = "echo \"heartbeat-$(date +%s)\""
        sshLog("💓 Sending post-command heartbeat check")
        
        // Set a 3-second timeout for the heartbeat
        var heartbeatCompleted = false
        
        let timeoutTask = DispatchWorkItem {
            if !heartbeatCompleted {
                sshLog("💓 Post-command heartbeat timed out after 3 seconds - triggering reconnect")
                Task { @MainActor [weak self] in
                    self?.handleConnectionLost()
                }
            }
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0, execute: timeoutTask)
        
        // Execute heartbeat
        client.executeCommandBypassingHeartbeat(heartbeatCommand, description: "Post-command heartbeat") { result in
            heartbeatCompleted = true
            timeoutTask.cancel()
            
            switch result {
            case .success(let output):
                if output.contains("heartbeat-") {
                    sshLog("💓 Post-command heartbeat successful: \(output)")
                } else {
                    sshLog("💓 Post-command heartbeat invalid response - triggering reconnect")
                    Task { @MainActor [weak self] in
                        self?.handleConnectionLost()
                    }
                }
            case .failure(let error):
                sshLog("💓 Post-command heartbeat failed: \(error) - triggering reconnect")
                Task { @MainActor [weak self] in
                    self?.handleConnectionLost()
                }
            }
        }
    }
    
    /// Verifies that the connection is alive and responsive
    /// Useful for proactive connection health checks
    func verifyConnectionHealth() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let heartbeatCommand = "echo \"health-check-$(date +%s)\""
            sshLog("💓 Executing connection health check")
            
            client.executeCommandBypassingHeartbeat(heartbeatCommand, description: "Connection health check") { result in
                switch result {
                case .success(let output):
                    if output.contains("health-check-") {
                        sshLog("💓 Connection health check successful")
                        continuation.resume()
                    } else {
                        sshLog("💓 Connection health check invalid response")
                        continuation.resume(throwing: SSHError.channelError("Invalid health check response"))
                    }
                case .failure(let error):
                    sshLog("💓 Connection health check failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - SSHClientProtocol Conformance
    
    /// Protocol-required connect method with completion handler
    nonisolated func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                try await self.connect(host: host, username: username, password: password)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
    

    
    // executeCommandWithNewChannel is already implemented above with heartbeat protection
} 
