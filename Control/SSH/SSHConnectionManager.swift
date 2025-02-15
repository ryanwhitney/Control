import Foundation
import SwiftUI

@MainActor
class SSHConnectionManager: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    private nonisolated let sshClient: SSHClient
    private var currentCredentials: Credentials?
    private var connectionLostHandler: (@MainActor () -> Void)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
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
        print("\n=== SSHConnectionManager: Initializing ===")
        self.sshClient = SSHClient()
    }
    
    func setConnectionLostHandler(_ handler: @escaping @MainActor () -> Void) {
        self.connectionLostHandler = handler
    }
    
    nonisolated var client: SSHClient { 
        print("SSHConnectionManager: Accessing SSH client")
        return sshClient 
    }
    
    func handleConnectionLost() {
        print("\n=== SSHConnectionManager: Connection Lost ===")
        Task { @MainActor in
            // Clean up existing connection
            disconnect()
            
            // If we have credentials, try to reconnect once
            if let credentials = currentCredentials {
                print("Attempting to reconnect...")
                do {
                    try await connect(
                        host: credentials.host,
                        username: credentials.username,
                        password: credentials.password
                    )
                    print("✓ Reconnection successful")
                } catch {
                    print("❌ Reconnection failed, notifying handler")
                    connectionLostHandler?()
                }
            } else {
                print("No credentials available for reconnection")
                connectionLostHandler?()
            }
        }
    }
    
    func connect(host: String, username: String, password: String) async throws {
        print("\n=== SSHConnectionManager: Connection Request ===")
        print("Host: \(host)")
        print("Username: \(username)")
        print("Password length: \(password.count)")
        print("Current state: \(connectionState.description)")
        
        // If we're already connected with same credentials, no need to reconnect
        if case .connected = connectionState,
           let existing = currentCredentials,
           existing.host == host,
           existing.username == username,
           existing.password == password {
            print("✓ Already connected with same credentials")
            return
        }
        
        // If we're in the process of connecting, don't start another connection
        if case .connecting = connectionState {
            print("⚠️ Connection already in progress")
            throw SSHError.connectionFailed("Connection already in progress")
        }
        
        // Clean up any existing connection
        await cleanupExistingConnection()
        
        connectionState = .connecting
        currentCredentials = Credentials(host: host, username: username, password: password)
        
        return try await withCheckedThrowingContinuation { continuation in
            print("\nAttempting connection...")
            let client = self.client // Capture nonisolated client
            Task {
                client.connect(host: host, username: username, password: password) { result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            print("✓ Connection successful")
                            self.connectionState = .connected
                            continuation.resume()
                        case .failure(let error):
                            print("❌ Connection failed: \(error)")
                            self.connectionState = .failed(error.localizedDescription)
                            self.currentCredentials = nil
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    
    func verifyConnection(host: String, username: String, password: String) async throws {
        print("\n=== SSHConnectionManager: Verifying Connection ===")
        try await connect(host: host, username: username, password: password)
        
        // If we get here, connection was successful
        // Immediately disconnect since this was just a verification
        disconnect()
    }
    
    private func cleanupExistingConnection() async {
        print("\n=== SSHConnectionManager: Cleaning up existing connection ===")
        if case .connected = connectionState {
            print("Found existing connection, disconnecting...")
            disconnect()
            // Give a small delay to ensure cleanup
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }
    
    nonisolated func disconnect() {
        print("\n=== SSHConnectionManager: Disconnecting ===")
        sshClient.disconnect()
        Task { @MainActor in
            print("Current state before disconnect: \(self.connectionState.description)")
            self.connectionState = .disconnected
            self.currentCredentials = nil
            print("✓ Disconnected")
        }
    }
    
    nonisolated func disconnectSync() {
        print("\n=== SSHConnectionManager: Sync Disconnecting ===")
        sshClient.disconnect()
    }
    
    deinit {
        print("\n=== SSHConnectionManager: Deinitializing ===")
        disconnectSync()
    }
    
    func shouldReconnect(host: String, username: String, password: String) -> Bool {
        guard case .connected = connectionState else { return true }
        
        // Check if we're already connected with the same credentials
        if let existing = currentCredentials,
           existing.host == host,
           existing.username == username,
           existing.password == password {
            print("✓ Already connected with same credentials")
            return false
        }
        
        return true
    }
    
    // MARK: - Lifecycle Management
    
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        print("\n=== SSHConnectionManager: Scene Phase Change ===")
        print("Old phase: \(oldPhase)")
        print("New phase: \(newPhase)")
        
        switch newPhase {
        case .active:
            print("Scene became active")
            endBackgroundTask()
            // Reconnection will be handled by the view when needed
            
        case .inactive:
            print("Scene became inactive")
            // No action needed, keep connection alive
            
        case .background:
            print("Scene entering background")
            startBackgroundTask()
            Task { @MainActor in
                disconnect()
            }
            
        @unknown default:
            print("Unknown scene phase: \(newPhase)")
        }
    }
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
} 