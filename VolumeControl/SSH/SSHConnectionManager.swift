import Foundation
import SwiftUI

@MainActor
class SSHConnectionManager: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    private nonisolated let sshClient: SSHClient
    private var currentCredentials: Credentials?
    
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
    
    nonisolated var client: SSHClient { 
        print("SSHConnectionManager: Accessing SSH client")
        return sshClient 
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
    
    private func cleanupExistingConnection() async {
        print("\n=== SSHConnectionManager: Cleaning up existing connection ===")
        if case .connected = connectionState {
            print("Found existing connection, disconnecting...")
            disconnect()
            // Give a small delay to ensure cleanup
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }
    
    func reconnectIfNeeded() {
        print("\n=== SSHConnectionManager: Checking Reconnection ===")
        print("Current state: \(connectionState.description)")
        
        guard case .disconnected = connectionState,
              let credentials = currentCredentials else {
            print("⚠️ No reconnection needed")
            return
        }
        
        print("Initiating reconnection...")
        Task {
            do {
                try await connect(
                    host: credentials.host,
                    username: credentials.username,
                    password: credentials.password
                )
                print("✓ Reconnection successful")
            } catch {
                print("❌ Reconnection failed: \(error)")
            }
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
} 