import SwiftUI
import Foundation

/// Protocol for views that need SSH connectivity
protocol SSHConnectedView: View {
    var host: String { get }
    var displayName: String { get }
    var username: String { get }
    var password: String { get }
    var connectionManager: SSHConnectionManager { get }
    var showingConnectionLostAlert: Binding<Bool> { get }
    var connectionError: Binding<(title: String, message: String)?> { get }
    var showingError: Binding<Bool> { get }
    
    /// Called when SSH connection succeeds
    func onSSHConnected()
    /// Called when SSH connection fails
    func onSSHConnectionFailed(_ error: Error)
}

extension SSHConnectedView {
    
    /// Set up SSH connection with all common patterns
    @MainActor
    func setupSSHConnection() {
        logConnectionMetadata()
        setConnectionLostHandler()
        connectToSSH()
    }
    
    /// Handle scene phase changes with health check logic
    @MainActor
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        viewLog("\(Self.self): Scene phase changed from \(oldPhase) to \(newPhase)", view: String(describing: Self.self))
        
        if newPhase == .active {
            Task { @MainActor in
                if connectionManager.connectionState == .connected {
                    do {
                        try await connectionManager.verifyConnectionHealth()
                        viewLog("✓ \(Self.self): Connection health verified", view: String(describing: Self.self))
                    } catch {
                        viewLog("❌ \(Self.self): Connection health check failed: \(error)", view: String(describing: Self.self))
                        connectToSSH()
                    }
                } else {
                    connectToSSH()
                }
            }
        }
        
        connectionManager.handleScenePhaseChange(from: oldPhase, to: newPhase)
    }
    
    /// Standard SSH connection lost alert
    func connectionLostAlert() -> Alert {
        Alert(
            title: Text("Connection Lost"),
            message: Text(SSHError.timeout.formatError(displayName: displayName).message),
            dismissButton: .default(Text("OK"))
        )
    }
    
    /// Standard SSH error alert
    func connectionErrorAlert() -> Alert {
        Alert(
            title: Text(connectionError.wrappedValue?.title ?? ""),
            message: Text(connectionError.wrappedValue?.message ?? ""),
            dismissButton: .cancel(Text("OK"))
        )
    }
    
    // MARK: - Private Implementation
    
    @MainActor
    private func logConnectionMetadata() {
        let isLocal = host.contains(".local")
        let connectionType = isLocal ? "SSH over Bonjour (.local)" : "SSH over TCP/IP"
        let hostRedacted = String(host.prefix(3)) + "***"
        
        viewLog("Target: \(hostRedacted)", view: String(describing: Self.self))
        viewLog("Protocol: \(connectionType)", view: String(describing: Self.self))
        viewLog("Display name: \(String(displayName.prefix(3)))***", view: String(describing: Self.self))
    }
    
    @MainActor
    private func setConnectionLostHandler() {
        connectionManager.setConnectionLostHandler { @MainActor in
            viewLog("⚠️ \(Self.self): Connection lost handler triggered", view: String(describing: Self.self))
            showingConnectionLostAlert.wrappedValue = true
        }
    }
    
    @MainActor
    private func connectToSSH() {
        viewLog("\(Self.self): Starting SSH connection", view: String(describing: Self.self))
        viewLog("Connection manager state: \(connectionManager.connectionState)", view: String(describing: Self.self))
        
        connectionManager.handleConnection(
            host: host,
            username: username,
            password: password,
            onSuccess: { 
                viewLog("✓ \(Self.self): SSH connection successful", view: String(describing: Self.self))
                onSSHConnected()
            },
            onError: { error in
                viewLog("❌ \(Self.self): SSH connection failed: \(error)", view: String(describing: Self.self))
                
                if let sshError = error as? SSHError {
                    connectionError.wrappedValue = sshError.formatError(displayName: displayName)
                } else {
                    connectionError.wrappedValue = (
                        "Connection Error",
                        "An unexpected error occurred: \(error.localizedDescription)"
                    )
                }
                showingError.wrappedValue = true
                onSSHConnectionFailed(error)
            }
        )
    }
} 