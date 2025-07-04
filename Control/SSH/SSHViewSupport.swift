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
        let viewName = String(describing: Self.self)
        viewLog("\(viewName): Scene phase changed from \(oldPhase) to \(newPhase)", view: viewName)
        
        if newPhase == .active {
            let currentViewName = viewName
            Task { @MainActor in
                if connectionManager.connectionState == .connected {
                    do {
                        try await connectionManager.verifyConnectionHealth()
                        viewLog("✓ \(currentViewName): Connection health verified", view: currentViewName)
                    } catch {
                        viewLog("❌ \(currentViewName): Connection health check failed: \(error)", view: currentViewName)
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
        
        let viewNameMeta = String(describing: Self.self)
        viewLog("Target: \(hostRedacted)", view: viewNameMeta)
        viewLog("Protocol: \(connectionType)", view: viewNameMeta)
        viewLog("Display name: \(String(displayName.prefix(3)))***", view: viewNameMeta)
    }
    
    @MainActor
    private func setConnectionLostHandler() {
        let viewNameMeta = String(describing: Self.self)
        connectionManager.setConnectionLostHandler { @MainActor in
            viewLog("⚠️ \(viewNameMeta): Connection lost handler triggered", view: viewNameMeta)
            showingConnectionLostAlert.wrappedValue = true
        }
    }
    
    @MainActor
    private func connectToSSH() {
        let viewName = String(describing: Self.self)
        viewLog("\(viewName): Starting SSH connection", view: viewName)
        viewLog("Connection manager state: \(connectionManager.connectionState)", view: viewName)
        
        connectionManager.handleConnection(
            host: host,
            username: username,
            password: password,
            onSuccess: { 
                viewLog("✓ \(viewName): SSH connection successful", view: viewName)
                onSSHConnected()
            },
            onError: { error in
                viewLog("❌ \(viewName): SSH connection failed: \(error)", view: viewName)
                
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