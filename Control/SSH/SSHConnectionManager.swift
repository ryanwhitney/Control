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
            connectionState = .disconnected
            disconnect()
            connectionLostHandler?()
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
        print("✓ Connection verified and maintained")
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
            
        case .inactive:
            print("Scene became inactive")
            // No action needed, keep connection alive
            
        case .background:
            print("Scene entering background")
            startBackgroundTask()
            // Only disconnect if background task expires (after ~30 seconds)
            print("Maintaining connection in background")
            
        @unknown default:
            print("Unknown scene phase: \(newPhase)")
        }
    }
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Background task is about to expire, disconnect to clean up resources
            print("Background task expiring, disconnecting SSH")
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
        print("\n=== SSHConnectionManager: Handling Connection ===")
        Task {
            do {
                if !shouldReconnect(host: host, username: username, password: password) {
                    print("✓ Using existing connection")
                    await onSuccess()
                    return
                }
                
                try await connect(host: host, username: username, password: password)
                print("✓ Connection established")
                await onSuccess()
            } catch {
                print("❌ Connection failed: \(error)")
                onError(error)
            }
        }
    }
    
    // Centralized connection loss detection
    nonisolated func isConnectionLossError(_ error: Error) -> Bool {
        let errorString = error.localizedDescription.lowercased()
        return errorString.contains("connection lost") ||
               errorString.contains("eof") ||
               errorString.contains("connection reset") ||
               errorString.contains("broken pipe") ||
               errorString.contains("connection closed") ||
               errorString.contains("tcp shutdown")
    }
    
    // Add connection loss detection to command execution
    nonisolated func executeCommandWithNewChannel(_ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        client.executeCommandWithNewChannel(command, description: description) { [weak self] result in
            if case .failure(let error) = result {
                if self?.isConnectionLossError(error) == true {
                    print("Connection loss detected during command execution")
                    Task { @MainActor [weak self] in
                        self?.handleConnectionLost()
                    }
                }
            }
            completion(result)
        }
    }
} 
