import SwiftUI
import Foundation
import Network

struct ConnectionsView: View {
    @StateObject private var viewModel = ConnectionsViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.hasConnections {
                    // The help button lives inside the list so it can float when
                    // the list is short and scroll under the rows when it's tall.
                    ConnectionsListView()
                } else {
                    EmptyStateView(
                        isSearching: viewModel.isSearching,
                        onRefresh: viewModel.startNetworkScan
                    )
                    HelpButtonView(
                        hasConnections: false,
                        onHelp: { viewModel.activePopover = .help }
                    )
                }
            }
            .refreshable {
                await withCheckedContinuation { continuation in
                    if viewModel.isSearching {
                        // Already searching, end refresh immediately
                        viewLog("Refresh requested but already searching", view: "ConnectionsView")
                        continuation.resume()
                    } else {
                        // Start scan and end pull-to-refresh immediately
                        // Our custom progress indicator will show the scan status
                        viewModel.startNetworkScan()
                        viewLog("Pull-to-refresh initiated, using custom progress indicator", view: "ConnectionsView")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            continuation.resume()
                        }
                    }
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 4) {
                        Text("Control".uppercased())
                            .font(.system(size: 14, weight: .bold, design: .default).width(.expanded))
                    }
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: viewModel.startNetworkScan) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Rescan for devices")

                        Button(action: {
                            viewModel.selectedConnection = nil
                            viewModel.username = ""
                            viewModel.password = ""
                            viewModel.saveCredentials = true
                            viewModel.showingAddDialog = true
                        }) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add new connection")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.activePopover = .preferences
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationTitle("")
            .accessibilityLabel("Control App - Connections List - Home")
            .accessibilityAddTraits(.isHeader)
            .sheet(isPresented: $viewModel.showingAddDialog) {
                AddConnectionSheet()
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $viewModel.isAuthenticating) {
                AuthenticationSheet()
                    .environmentObject(viewModel)
            }
            .alert(viewModel.connectionError?.title ?? "", isPresented: $viewModel.showingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.connectionError?.message ?? "")
            }
            .navigationDestination(isPresented: $viewModel.showingSetupFlow) {
                SetupFlowDestination()
            }
            .navigationDestination(isPresented: $viewModel.navigateToControl) {
                ControlDestination()
            }
            .sheet(item: $viewModel.activePopover) { popover in
                switch popover {
                case .help:
                    NavigationView {
                        RemoteLoginInstructions()
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                case .preferences:
                    PreferencesView()
                }
            }
            .sheet(isPresented: $viewModel.showingWhatsNew) {
                WhatsNewView {
                    viewModel.showingWhatsNew = false
                }
                .presentationBackground(.black)
                .presentationDetents([.large])
                .presentationCornerRadius(20)
                .interactiveDismissDisabled(true)
            }
            .tint(UserPreferences.shared.tintColorValue)
        }
        .environmentObject(viewModel)
        .onAppear {
            // Root views don't disappear, so these only run on app open or foreground
            SSHConnectionManager.shared.disconnect()
            viewModel.onAppear()
        }
        .onDisappear(perform: viewModel.onDisappear)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            viewModel.handleScenePhaseChange(from: oldPhase, to: newPhase)
            
            // Rescan when app comes to foreground if enough time has passed
            if oldPhase != .active && newPhase == .active {
                viewLog("App came to foreground, checking if rescan needed", view: "ConnectionsView")
                viewModel.checkForRescanOnForeground()
            }
        }
        .onChange(of: viewModel.navigateToControl) { oldVal, newVal in
            // When we return from ControlView to the connections list, tear down any live SSH session
            if oldVal == true && newVal == false {
                SSHConnectionManager.shared.disconnect()
                viewLog("ConnectionsView: navigateToControl -> false, disconnected active SSH session", view: "ConnectionsView")
            }

            if !newVal {
                viewModel.connectingComputer = nil
                viewModel.selectedConnection = nil
            }
        }
        .onChange(of: viewModel.showingSetupFlow) { _, newValue in
            if !newValue {
                // Backing out of first-time setup leaves the SSH session from
                // PermissionsView/ChooseAppsView live — tear it down like the
                // ControlView return path above. Setup *completion* instead
                // hands the connection to ControlView (navigateToControl is
                // already true by the time this fires), so leave it alone then.
                if !viewModel.navigateToControl {
                    SSHConnectionManager.shared.disconnect()
                    viewLog("ConnectionsView: setup flow dismissed, disconnected active SSH session", view: "ConnectionsView")
                }
                viewModel.connectingComputer = nil
            }
        }
        .onChange(of: viewModel.showingError) { _, newValue in
            if !newValue {
                viewModel.connectingComputer = nil
                if viewModel.lastErrorWasAuthFailure {
                    // Re-prompt for credentials - keep selectedConnection and username
                    viewModel.password = ""
                    viewModel.lastErrorWasAuthFailure = false
                    viewModel.isAuthenticating = true
                } else {
                    viewModel.selectedConnection = nil
                    viewModel.username = ""
                    viewModel.password = ""
                }
            }
        }
    }
}

// MARK: - Sheet Views

private struct AddConnectionSheet: View {
    @EnvironmentObject private var viewModel: ConnectionsViewModel

        var body: some View {
        if let computer = viewModel.selectedConnection {
            AuthenticationView(
                mode: .edit,
                existingHost: computer.host,
                existingName: computer.name,
                username: $viewModel.username,
                password: $viewModel.password,
                saveCredentials: $viewModel.saveCredentials,
                onSuccess: { _, nickname in
                    viewModel.updateCredentials(
                        hostname: computer.host,
                        name: nickname ?? computer.name,
                        username: viewModel.username,
                        password: viewModel.password,
                        saveCredentials: viewModel.saveCredentials
                    )
                    viewModel.showingAddDialog = false
                    viewModel.selectedConnection = nil
                },
                onCancel: {
                    viewModel.showingAddDialog = false
                    viewModel.selectedConnection = nil
                }
            )
        } else {
            AuthenticationView(
                mode: .add,
                username: $viewModel.username,
                password: $viewModel.password,
                saveCredentials: .init(get: { true }, set: { viewModel.saveCredentials = $0 }),
                onSuccess: { hostname, nickname in
                    let newComputer = Connection(
                        id: hostname,
                        name: nickname ?? hostname,
                        host: hostname,
                        type: .manual,
                        lastUsername: viewModel.username
                    )
                    viewModel.showingAddDialog = false
                    viewModel.connectWithNewCredentials(computer: newComputer)
                },
                onCancel: { viewModel.showingAddDialog = false }
            )
        }
    }
}

private struct AuthenticationSheet: View {
    @EnvironmentObject private var viewModel: ConnectionsViewModel
    
    var body: some View {
        if let computer = viewModel.selectedConnection {
            AuthenticationView(
                mode: .authenticate,
                existingHost: computer.host,
                existingName: computer.name,
                username: $viewModel.username,
                password: $viewModel.password,
                saveCredentials: $viewModel.saveCredentials,
                onSuccess: { _, nickname in
                    let updatedComputer = Connection(
                        id: computer.id,
                        name: nickname ?? computer.name,
                        host: computer.host,
                        type: computer.type,
                        lastUsername: computer.lastUsername
                    )
                    viewModel.connectWithNewCredentials(computer: updatedComputer)
                },
                onCancel: {
                    viewModel.isAuthenticating = false
                }
            )
            .presentationDragIndicator(.visible)
        }
    }
}

private struct SetupFlowDestination: View {
    @EnvironmentObject private var viewModel: ConnectionsViewModel

    var body: some View {
        if let computer = viewModel.selectedConnection {
            SetupFlowView(
                host: computer.host,
                displayName: computer.name,
                username: viewModel.username,
                password: viewModel.password,
                isReconfiguration: false,
                onComplete: {
                    viewLog("⛵︎ First-time setup completed, navigating to ControlView", view: "ConnectionsView")
                    viewModel.showingSetupFlow = false
                    viewModel.navigateToControl = true
                }
            )
            .environmentObject(viewModel.savedConnections)
        }
    }
}

private struct ControlDestination: View {
    @EnvironmentObject private var viewModel: ConnectionsViewModel

    var body: some View {
        if let computer = viewModel.selectedConnection {
            ControlView(
                host: computer.host,
                displayName: computer.name,
                username: viewModel.username,
                password: viewModel.password
            )
            .environmentObject(viewModel.savedConnections)
        }
    }
}

// MARK: - Previews

#Preview("Live SSH Connection") {
    ConnectionsView()
}

@MainActor
/// No-op subclass for SwiftUI previews: every action that would touch the
/// network, keychain, or SSH is overridden to do nothing.
private class MockConnectionsViewModelForPreview: ConnectionsViewModel {
    override func startNetworkScan() {}
    override func selectComputer(_ computer: Connection) {}
    override func deleteConnection(hostname: String) {}
    override func editConnection(_ computer: Connection) {}
    override func connectWithCredentials(computer: Connection) {}
    override func connectWithNewCredentials(computer: Connection) {}
    override func onAppear() {}
    override func onDisappear() {}
}

#Preview("With Mock Data") {
    @Previewable @StateObject var mockViewModel = MockConnectionsViewModelForPreview()
    
    NavigationStack {
    ConnectionsView()
    }
    .environmentObject(mockViewModel)
}
