import Foundation
import SwiftUI

@MainActor
class SSHConnectionManager: ObservableObject {
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
        let connectionType = isLocal ? "SSH over Bonjour (.local)" : "SSH over TCP/IP"
        let hostRedacted = String(host.prefix(1)) + "***"
        
        connectionLog("Protocol: \(connectionType)")
        connectionLog("Target: \(hostRedacted)")
        connectionLog("Port: 22 (SSH)")
        connectionLog("Username: \(String(username.prefix(1)))***")
//        connectionLog("Password length: \(password.count)")
        connectionLog("Current state: \(connectionState.description)")
        
        // If we're already connected with same credentials, no need to reconnect
        if case .connected = connectionState,
           let existing = currentCredentials,
           existing.host == host,
           existing.username == username,
           existing.password == password {
            connectionLog("✓ Already connected with same credentials")
            return
        }
        
        // If we're in the process of connecting, don't start another connection
        if case .connecting = connectionState {
            connectionLog("⚠️ Connection already in progress")
            throw SSHError.connectionFailed("Connection already in progress")
        }
        
        // Clean up any existing connection
        await cleanupExistingConnection()
        
        let previousState = connectionState.description
        connectionState = .connecting
        connectionLog("Connection state changed: \(previousState) -> \(connectionState.description)")
        currentCredentials = Credentials(host: host, username: username, password: password)
        
        return try await withCheckedThrowingContinuation { continuation in
            connectionLog("Attempting connection...")
            let client = self.client // Capture nonisolated client
            Task {
                client.connect(host: host, username: username, password: password) { result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            connectionLog("✓ Connection successful")
                            let previousState = self.connectionState.description
                            self.connectionState = .connected
                            connectionLog("Connection state changed: \(previousState) -> \(self.connectionState.description)")
                            continuation.resume()
                        case .failure(let error):
                            connectionLog("❌ Connection failed: \(error)")
                            let previousState = self.connectionState.description
                            self.connectionState = .failed(error.localizedDescription)
                            connectionLog("Connection state changed: \(previousState) -> \(self.connectionState.description)")
                            self.currentCredentials = nil
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    
    func verifyConnection(host: String, username: String, password: String) async throws {
        connectionLog("Verifying connection")
        try await connect(host: host, username: username, password: password)
        
        // If we get here, connection was successful
        // Keep connection alive for subsequent use instead of disconnecting
        connectionLog("✓ Connection verified and maintained")
    }
    
    private func cleanupExistingConnection() async {
        connectionLog("SSHConnectionManager: Cleaning up existing connection")
        if case .connected = connectionState {
            connectionLog("Found existing connection, disconnecting...")
            disconnect()
            // Give a small delay to ensure cleanup
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }
    
    nonisolated func disconnect() {
        sshLog("SSHConnectionManager: Starting disconnect process")
        sshClient.disconnect()
        Task { @MainActor in
            let previousState = self.connectionState.description
            sshLog("Connection state before disconnect: \(previousState)")
            self.connectionState = .disconnected
            self.currentCredentials = nil
            sshLog("✓ SSHConnectionManager disconnected")
        }
    }
    
    nonisolated func disconnectSync() {
        sshLog("SSHConnectionManager: Sync disconnect requested")
        sshClient.disconnect()
    }
    
    deinit {
        sshLog("SSHConnectionManager: Deinitializing")
        disconnectSync()
    }
    
    func shouldReconnect(host: String, username: String, password: String) -> Bool {
        guard case .connected = connectionState else { 
            connectionLog("Should reconnect: Not connected (current state: \(connectionState.description))")
            return true 
        }
        
        // Check if we're already connected with the same credentials
        if let existing = currentCredentials,
           existing.host == host,
           existing.username == username,
           existing.password == password {
            connectionLog("✓ Already connected with same credentials - no reconnect needed")
            return false
        }
        
        connectionLog("Should reconnect: Credentials have changed")
        return true
    }
    
    // MARK: - Lifecycle Management
    
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        connectionLog("SSHConnectionManager: Scene phase change")
        connectionLog("Phase transition: \(oldPhase) -> \(newPhase)")
        connectionLog("Current connection state: \(connectionState.description)")
        
        switch newPhase {
        case .active:
            connectionLog("Scene became active - ending background task")
            endBackgroundTask()
            
        case .inactive:
            connectionLog("Scene became inactive - keeping connection alive")
            // No action needed, keep connection alive
            
        case .background:
            connectionLog("Scene entering background - starting background task")
            startBackgroundTask()
            // Only disconnect if background task expires (after ~30 seconds)
            connectionLog("Maintaining connection in background")
            
        @unknown default:
            connectionLog("Unknown scene phase: \(newPhase)")
        }
    }
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Background task is about to expire, disconnect to clean up resources
            connectionLog("Background task expiring - disconnecting SSH")
            self?.disconnect()
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
        connectionLog("Handling connection")
        Task {
            do {
                if !shouldReconnect(host: host, username: username, password: password) {
                    connectionLog("✓ Using existing connection")
                    await onSuccess()
                    return
                }
                
                try await connect(host: host, username: username, password: password)
                connectionLog("✓ Connection established")
                await onSuccess()
            } catch {
                connectionLog("❌ Connection failed: \(error)")
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
    
    // Add connection loss detection to command execution
    nonisolated func executeCommandWithNewChannel(_ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        sshLog("SSHConnectionManager: Executing command via new channel")
        if let description = description {
            sshLog("Command: \(description)")
        }
        
        client.executeCommandWithNewChannel(command, description: description) { [weak self] result in
            switch result {
            case .success(_):
                sshLog("✓ Command completed successfully")
                completion(result)
            case .failure(let error):
                sshLog("❌ Command failed: \(error)")
                if self?.isConnectionLossError(error) == true {
                    sshLog("🚨 Connection loss detected during command execution")
                    Task { @MainActor [weak self] in
                        self?.handleConnectionLost()
                    }
                }
                completion(result)
            }
        }
    }
} 
