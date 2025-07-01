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
            self.cancelBackgroundDisconnect()
            self.endBackgroundTask()
        }
    }
    
    deinit {
        sshClient.disconnect()
        Task { @MainActor in
            self.cancelBackgroundDisconnect()
            self.endBackgroundTask()
        }
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
    
    private var backgroundDisconnectTimer: DispatchWorkItem?
    private var lastScenePhaseChange: (from: ScenePhase, to: ScenePhase, time: Date)?
    
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        // Debounce duplicate calls (multiple views calling this simultaneously)
        let now = Date()
        if let last = lastScenePhaseChange,
           last.from == oldPhase && last.to == newPhase,
           now.timeIntervalSince(last.time) < 0.1 {
            return // Ignore duplicate call within 100ms
        }
        
        lastScenePhaseChange = (oldPhase, newPhase, now)
        connectionLog("Scene phase: \(oldPhase) -> \(newPhase)")
        
        switch newPhase {
        case .active:
            cancelBackgroundDisconnect()
            endBackgroundTask()
        case .inactive:
            // No action needed, keep connection alive briefly
            break
        case .background:
            startBackgroundDisconnectTimer()
        @unknown default:
            connectionLog("Unknown scene phase: \(newPhase)")
        }
    }
    
    private func startBackgroundDisconnectTimer() {
        // Cancel any existing timer
        cancelBackgroundDisconnect()
        
        // Start background task to prevent immediate termination
        startBackgroundTask()
        
        // Set up 30-second timer to disconnect SSH
        let disconnectTimer = DispatchWorkItem { [weak self] in
            connectionLog("📱 App backgrounded for 30 seconds - disconnecting SSH")
            self?.disconnect()
            self?.endBackgroundTask()
        }
        
        backgroundDisconnectTimer = disconnectTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: disconnectTimer)
        connectionLog("📱 Started 30-second background disconnect timer")
    }
    
    private func cancelBackgroundDisconnect() {
        backgroundDisconnectTimer?.cancel()
        backgroundDisconnectTimer = nil
        connectionLog("📱 Cancelled background disconnect timer")
    }
    
    private func startBackgroundTask() {
        // End any existing background task first
        endBackgroundTask()
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SSH Connection Cleanup") { [weak self] in
            // Background task is about to expire (system limit ~30-180 seconds)
            connectionLog("📱 Background task expiring - disconnecting SSH")
            self?.client.disconnect()
            self?.disconnect() 
            self?.endBackgroundTask()
        }
        
        if backgroundTask == .invalid {
            connectionLog("⚠️ Failed to start background task")
        } else {
            connectionLog("📱 Started background task: \(backgroundTask)")
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            connectionLog("📱 Ending background task: \(backgroundTask)")
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
    
    /// Execute a command with proactive timeout-based connection monitoring
    /// 
    /// This method includes a heartbeat mechanism that:
    /// - Starts a timeout timer when the command is sent
    /// - Triggers reconnection if no response (success OR failure) within 6 seconds
    /// - Prevents silent hangs by detecting dead connections proactively
    /// - Sends heartbeat verification after successful commands
    nonisolated func executeCommand(_ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        sshLog("SSHConnectionManager: Executing command with proactive timeout monitoring")
        if let description = description {
            sshLog("Command: \(description)")
        }
        
        let commandId = UUID().uuidString.prefix(8)
        var hasCompleted = false
        let startTime = Date()
        
        // Start proactive timeout monitoring
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard !hasCompleted else { return }
            hasCompleted = true
            
            let elapsed = Date().timeIntervalSince(startTime)
            sshLog("⏰ [\(commandId)] Command timed out after \(String(format: "%.1f", elapsed))s with no response")
            sshLog("💓 [\(commandId)] Proactive heartbeat timeout - connection appears dead")
            
            // Connection appears dead - trigger reconnection
            Task { @MainActor [weak self] in
                self?.handleConnectionLost()
            }
            completion(.failure(SSHError.timeout))
        }
        
        sshLog("⏰ [\(commandId)] Starting 6-second proactive timeout monitor")
        DispatchQueue.global().asyncAfter(deadline: .now() + 6.0, execute: timeoutTask)
        
        // Execute the command
        client.executeCommandWithNewChannel(command, description: description) { [weak self] result in
            guard !hasCompleted else { 
                sshLog("⚠️ [\(commandId)] Command completed but timeout already triggered, ignoring result")
                return 
            }
            hasCompleted = true
            timeoutTask.cancel()
            
            let elapsed = Date().timeIntervalSince(startTime)
            sshLog("⏰ [\(commandId)] Command completed in \(String(format: "%.1f", elapsed))s")
            
            switch result {
            case .success(let output):
                sshLog("✓ [\(commandId)] Command succeeded, sending verification heartbeat")
                // Command succeeded, send verification heartbeat
                self?.sendPostCommandHeartbeat { heartbeatResult in
                    switch heartbeatResult {
                    case .success:
                        sshLog("💓 [\(commandId)] Post-command heartbeat successful")
                        completion(.success(output))
                    case .failure(let heartbeatError):
                        sshLog("💓 [\(commandId)] Post-command heartbeat failed: \(heartbeatError)")
                        // Heartbeat failed - connection is likely dead
                        Task { @MainActor [weak self] in
                            self?.handleConnectionLost()
                        }
                        completion(.failure(heartbeatError))
                    }
                }
            case .failure(let error):
                sshLog("❌ [\(commandId)] Command failed: \(error)")
                // Command failed, check if it's a connection issue
                if self?.isConnectionLossError(error) == true {
                    sshLog("🚨 [\(commandId)] Connection loss detected during command execution")
                    Task { @MainActor [weak self] in
                        self?.handleConnectionLost()
                    }
                }
                completion(.failure(error))
            }
        }
    }
    
    /// Send a heartbeat command to verify connection health after normal commands
    private nonisolated func sendPostCommandHeartbeat(completion: @escaping (Result<Void, Error>) -> Void) {
        let heartbeatId = UUID().uuidString.prefix(8)
        let heartbeatCommand = "echo \"heartbeat-\(heartbeatId)-$(date +%s)\""
        sshLog("💓 Sending post-command heartbeat: \(heartbeatId)")
        
        client.executeCommandBypassingHeartbeat(heartbeatCommand, description: "Post-command heartbeat") { result in
            switch result {
            case .success(let output):
                if output.contains("heartbeat-\(heartbeatId)") {
                    sshLog("💓 Heartbeat verified: connection is alive")
                    completion(.success(()))
                } else {
                    sshLog("💓 Heartbeat invalid response: \(output)")
                    completion(.failure(SSHError.channelError("Invalid heartbeat response")))
                }
            case .failure(let error):
                sshLog("💓 Heartbeat failed: \(error)")
                completion(.failure(error))
            }
        }
    }
    
    /// Verifies that the connection is alive and responsive
    func verifyConnectionHealth() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let healthCommand = "echo \"health-check-$(date +%s)\""
            sshLog("💓 Executing connection health check")
            
            client.executeCommandWithNewChannel(healthCommand, description: "Connection health check") { result in
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
    
    /// Compatibility alias for existing code
    nonisolated func executeCommandWithNewChannel(_ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        executeCommand(command, description: description, completion: completion)
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
