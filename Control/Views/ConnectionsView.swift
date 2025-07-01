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
                    ConnectionsListView()
                } else {
                    EmptyStateView(
                        isSearching: viewModel.isSearching,
                        onRefresh: viewModel.startNetworkScan
                    )
                }

                HelpButtonView(
                    hasConnections: viewModel.hasConnections,
                    onHelp: { viewModel.activePopover = .help }
                )
            }
            .refreshable {
                await withCheckedContinuation { continuation in
                    viewModel.startNetworkScan()
                    Task {
                        try await Task.sleep(nanoseconds: 8_000_000_000)
                        continuation.resume()
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
            .sheet(isPresented: $viewModel.showingAddDialog) {
                AddConnectionSheet()
            }
            .sheet(isPresented: $viewModel.isAuthenticating) {
                AuthenticationSheet()
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
        .onAppear(perform: viewModel.onAppear)
        .onDisappear(perform: viewModel.onDisappear)
        .onChange(of: scenePhase, viewModel.handleScenePhaseChange)
        .onChange(of: viewModel.navigateToControl) { _, newValue in
            if !newValue {
                viewModel.connectingComputer = nil
                viewModel.selectedConnection = nil
            }
        }
        .onChange(of: viewModel.showingSetupFlow) { _, newValue in
            if !newValue {
                viewModel.connectingComputer = nil
            }
        }
        .onChange(of: viewModel.showingError) { _, newValue in
            if !newValue {
                viewModel.connectingComputer = nil
                viewModel.selectedConnection = nil
                viewModel.username = ""
                viewModel.password = ""
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
                    viewLog("ConnectionsView: First-time setup completed, navigating to ControlView", view: "ConnectionsView")
                    viewModel.showingSetupFlow = false
                    viewModel.navigateToControl = true
                }
            )
            .environmentObject(SavedConnections())
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
            .environmentObject(SavedConnections())
        }
    }
}

// MARK: - Previews

#Preview("Live SSH Connection") {
    ConnectionsView()
}

@MainActor
private class MockConnectionsViewModelForPreview: ConnectionsViewModel {
    override init() {
        super.init()
    }
    
    override func startNetworkScan() {
        // Override to prevent actual scanning
    }
    
    override func selectComputer(_ computer: Connection) {
        // Override to prevent actual connections
    }
    
    override func deleteConnection(hostname: String) {
        // Override to prevent actual deletion
    }
    
    override func editConnection(_ computer: Connection) {
        // Override to prevent actual editing
    }
    
    override func connectWithCredentials(computer: Connection) {
        // Override to prevent actual connections
    }
    
    override func connectWithNewCredentials(computer: Connection) {
        // Override to prevent actual connections
    }
    
    override func onAppear() {
        // Override to prevent initialization
    }
    
    override func onDisappear() {
        // Override to prevent cleanup
    }
}

#Preview("With Mock Data") {
    @Previewable @StateObject var mockViewModel = MockConnectionsViewModelForPreview()
    
    NavigationStack {
    ConnectionsView()
    }
    .environmentObject(mockViewModel)
}
