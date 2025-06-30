import SwiftUI
import Foundation
import Network

struct ConnectionsView: View {
    @StateObject private var savedConnections = SavedConnections()
    @StateObject private var connectionManager = SSHConnectionManager.shared
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var connections: [NetService] = []
    @State private var networkScanner: NWBrowser?
    @State private var selectedConnection: Connection?
    @State private var connectingComputer: Connection?
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var saveCredentials = false
    @State private var isSearching = false
    @State private var isAuthenticating = false
    @State private var connectionError: (title: String, message: String)?
    @State private var showingAddDialog = false
    @State private var showingError = false
    @State private var showingSetupFlow = false
    @State private var navigateToControl = false
    @State private var activePopover: ActivePopover?

    enum ActivePopover: Identifiable {
        case help
        case preferences
        var id: Self { self }
    }

    struct Connection: Identifiable, Hashable {
        let id: String
        let name: String
        let host: String
        let type: ConnectionType
        var lastUsername: String?

        enum ConnectionType {
            case bonjour(NetService)
            case manual
        }

        static func == (lhs: Connection, rhs: Connection) -> Bool {
            return lhs.host == rhs.host
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(host)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if connections.isEmpty && savedConnections.items.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        if isSearching {
                            ProgressView()
                                .controlSize(.large)
                            Text("Searching...")
                                .foregroundStyle(.tertiary)
                        } else {
                            VStack(spacing: 16){
                                Image(systemName: "macbook.and.iphone")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 60, height: 40)
                                    .foregroundStyle(.tint)
                                Text("No connections found")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("Make sure your Mac is on the same network and has Remote Login enabled.")
                                    .foregroundStyle(.secondary)
                                Button(action: startNetworkScan) {
                                    Text("Refresh")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        }
                        Spacer()
                    }
                } else {
                    List {
                        Section(header: Text("On Your Network".capitalized)) {
                            if connections.isEmpty && isSearching {
                                HStack {
                                    Text("Scanning...")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    ProgressView()
                                }
                                .accessibilityLabel("Scanning for devices")
                            } else if connections.isEmpty {
                                Text("No connections found")
                                    .foregroundColor(.secondary)
                            }
                            ForEach(networkComputers) { computer in
                                ComputerRow(
                                    computer: computer,
                                    isConnecting: connectingComputer?.id == computer.id
                                ) {
                                    selectComputer(computer)
                                }
                                .accessibilityHint(connectingComputer?.id == computer.id ? "Currently connecting" : "Tap to connect")
                                .accessibilityAddTraits(connectingComputer?.id == computer.id ? .updatesFrequently : [])
                            }
                            if !connections.isEmpty && isSearching {
                                HStack {
                                    Text("Searching for others…")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    ProgressView()
                                }
                                .accessibilityLabel("Scanning for additional devices")
                            }
                        }
                        Section(header: Text("Recent".capitalized)) {
                            if savedComputers.isEmpty {
                                Text("No recent connections")
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(savedComputers) { computer in
                                    ComputerRow(
                                        computer: computer,
                                        isConnecting: connectingComputer?.id == computer.id
                                    ) {
                                        selectComputer(computer)
                                    }
                                    .accessibilityHint(connectingComputer?.id == computer.id ? "Currently connecting" : "Tap to connect")
                                    .accessibilityAddTraits(connectingComputer?.id == computer.id ? .updatesFrequently : [])
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            savedConnections.remove(hostname: computer.host)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .accessibilityLabel("Delete \(computer.name)")
                                        .tint(.red)

                                        Button {
                                            selectedConnection = computer
                                            username = computer.lastUsername ?? ""
                                            // Show bullets if password exists, empty if not
                                            password = savedConnections.password(for: computer.host) != nil ? "•••••" : ""
                                            saveCredentials = savedConnections.getSaveCredentialsPreference(for: computer.host)
                                            showingAddDialog = true
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .accessibilityLabel("Edit \(computer.name)")
                                        .tint(.accentColor)
                                    }
                                }
                            }
                        }
                        .accessibilityLabel("Recent connections")
                    }
                }
                VStack {
                    Spacer()
                    if connections.isEmpty && savedConnections.items.isEmpty {
                        Button {
                            activePopover = .help
                        } label: {
                            Label("Why isn't my device showing?", systemImage: "questionmark.circle.fill")
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(.thickMaterial)
                                .cornerRadius(12)
                                .tint(.accentColor)
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                    } else {
                        Button {
                            activePopover = .help
                        } label: {
                            Label("Why isn't my device showing?", systemImage: "questionmark.circle.fill")
                                .padding()
                                .frame(maxWidth: .infinity)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, connections.isEmpty && savedConnections.items.isEmpty ? 8 : 20)
            }
            .refreshable {
                await withCheckedContinuation { continuation in
                    startNetworkScan()
                    // Wait for scan timeout (8 seconds)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        continuation.resume()
                    }
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 4){
                        Text("Control".uppercased())
                            .font(.system(size: 14, weight: .bold, design: .default).width(.expanded))
                    }
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: startNetworkScan) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Rescan for devices")

                        Button(action: {
                            selectedConnection = nil
                            username = ""
                            password = ""
                            saveCredentials = true
                            showingAddDialog = true
                        }) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add new connection")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        activePopover = .preferences
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingAddDialog) {
                if let computer = selectedConnection {
                    // Edit mode
                    AuthenticationView(
                        mode: .edit,
                        existingHost: computer.host,
                        existingName: computer.name,
                        username: $username,
                        password: $password,
                        saveCredentials: $saveCredentials,
                        onSuccess: { _, nickname in
                            // Only update password if user actually changed it (not still bullets)
                            let passwordToSave: String?
                            if saveCredentials {
                                passwordToSave = password == "•••••" ? savedConnections.password(for: computer.host) : password
                            } else {
                                passwordToSave = nil
                            }
                            
                            savedConnections.updateLastUsername(
                                for: computer.host,
                                name: nickname ?? computer.name,
                                username: username,
                                password: passwordToSave,
                                saveCredentials: saveCredentials
                            )
                            showingAddDialog = false
                            selectedConnection = nil
                        },
                        onCancel: {
                            showingAddDialog = false
                            selectedConnection = nil
                        }
                    )
                } else {
                    // Add mode
                    AuthenticationView(
                        mode: .add,
                        username: $username,
                        password: $password,
                        saveCredentials: .init(get: { true }, set: { self.saveCredentials = $0 }),
                        onSuccess: { hostname, nickname in
                            savedConnections.add(
                                hostname: hostname,
                                name: nickname ?? hostname,
                                username: username,
                                password: password,
                                saveCredentials: saveCredentials
                            )
                            showingAddDialog = false
                        },
                        onCancel: { showingAddDialog = false }
                    )
                }
            }
            .sheet(isPresented: $isAuthenticating) {
                if let computer = selectedConnection {
                    AuthenticationView(
                        mode: .authenticate,
                        existingHost: computer.host,
                        existingName: computer.name,
                        username: $username,
                        password: $password,
                        saveCredentials: $saveCredentials,
                        onSuccess: { _, nickname in
                            if let nickname = nickname {
                                // Create new computer with updated name
                                let updatedComputer = Connection(
                                    id: computer.id,
                                    name: nickname,
                                    host: computer.host,
                                    type: computer.type,
                                    lastUsername: computer.lastUsername
                                )
                                verifyAndConnect(computer: updatedComputer)
                            } else {
                                verifyAndConnect(computer: computer)
                            }
                        },
                        onCancel: {
                            isAuthenticating = false
                        }
                    )
                    .presentationDragIndicator(.visible)
                }
            }
                    .alert(connectionError?.title ?? "", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(connectionError?.message ?? "")
        }
            .navigationDestination(isPresented: $showingSetupFlow) {
                if let computer = selectedConnection {
                    SetupFlowView(
                        host: computer.host,
                        displayName: computer.name,
                        username: username,
                        password: password,
                        isReconfiguration: false,
                        onComplete: {
                            viewLog("ConnectionsView: First-time setup completed, navigating to ControlView", view: "ConnectionsView")
                            showingSetupFlow = false
                            navigateToControl = true
                        }
                    )
                    .environmentObject(savedConnections)
                }
            }
            .navigationDestination(isPresented: $navigateToControl) {
                if let computer = selectedConnection {
                    ControlView(
                        host: computer.host,
                        displayName: computer.name,
                        username: username,
                        password: password
                    )
                    .environmentObject(savedConnections)
                }
            }
            .sheet(item: $activePopover) { popover in
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
            .tint(preferences.tintColorValue)
        }
        .onAppear {
            // Disconnect any existing connections when returning to connections view
            connectionManager.disconnect()
            startNetworkScan()
        }
        .onDisappear {
            networkScanner?.cancel()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            connectionManager.handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        .onChange(of: navigateToControl) { _, newValue in
            if !newValue {
                // Reset states when returning from ControlView
                connectingComputer = nil
                selectedConnection = nil
            }
        }
        .onChange(of: showingSetupFlow) { _, newValue in
            if !newValue {
                // Reset states when returning from setup flow
                connectingComputer = nil
            }
        }
        .onChange(of: showingError) { _, newValue in
            if newValue {
                // Reset states after error
                connectingComputer = nil
                selectedConnection = nil
                isAuthenticating = false
                username = ""
                password = ""
            }
        }
    }

    struct ComputerRow: View {
        let computer: Connection
        let isConnecting: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(computer.name)
                            .font(.headline)
                        Text(computer.host)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let username = computer.lastUsername {
                            Text(username)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if isConnecting {
                        ProgressView()
                    }
                }
            }
            .accessibilityLabel("Device")
            .accessibilityValue("\(computer.name) at host  \(computer.host); \(computer.lastUsername != nil ? "saved user: \(computer.lastUsername!)" : "")")
            .disabled(isConnecting)
        }
    }

    private var networkComputers: [Connection] {
        connections.compactMap { service in
            guard let hostname = service.hostName else { return nil }
            
            // Clean up the hostname by removing the extra period
            let cleanHostname = hostname.replacingOccurrences(of: ".local.", with: ".local")
            
            return Connection(
                id: service.name,
                name: service.name.replacingOccurrences(of: "\\032", with: ""),
                host: cleanHostname,
                type: .bonjour(service),
                lastUsername: savedConnections.lastUsername(for: cleanHostname)
            )
        }
    }
    
    private var savedComputers: [Connection] {
        savedConnections.items.map { saved in
            Connection(
                id: saved.hostname,
                name: saved.name ?? saved.hostname,
                host: saved.hostname,
                type: .manual,
                lastUsername: saved.username
            )
        }.sorted { $0.name < $1.name }
    }

    private func selectComputer(_ computer: Connection) {
        // Prevent multiple simultaneous connection attempts
        guard connectingComputer == nil else {
            viewLog("⚠️ Connection already in progress, ignoring tap", view: "ConnectionsView")
            return
        }
        
        selectedConnection = computer
        
        // Check if we have saved credentials
        if let savedConnection = savedConnections.items.first(where: { $0.hostname == computer.host }) {
            username = savedConnection.username ?? ""
            password = savedConnections.password(for: computer.host) ?? ""
            
            // If we have saved credentials, attempt to connect
            if !username.isEmpty && !password.isEmpty {
                verifyAndConnect(computer: computer)
            } else {
                // Show authentication dialog for missing credentials
                // Use the saved preference for this host
                saveCredentials = savedConnections.getSaveCredentialsPreference(for: computer.host)
                isAuthenticating = true
            }
        } else {
            // Show authentication dialog for new connection
            username = computer.lastUsername ?? ""
            password = ""
            // Use the saved preference for this host (defaults to true for new connections)
            saveCredentials = savedConnections.getSaveCredentialsPreference(for: computer.host)
            isAuthenticating = true
        }
    }
    
    private func verifyAndConnect(computer: Connection) {
        viewLog("ConnectionsView: Starting connection verification", view: "ConnectionsView")
        
        // Show connection metadata without exposing sensitive info
        let isLocal = computer.host.contains(".local")
        let connectionType = isLocal ? "Bonjour (.local)" : "Manual IP"
        viewLog("Connection type: \(connectionType)", view: "ConnectionsView")
        viewLog("Computer name: \(String(computer.name.prefix(3)))***", view: "ConnectionsView")
        viewLog("Host: \(String(computer.host.prefix(3)))***", view: "ConnectionsView")
        viewLog("Connection manager state: \(connectionManager.connectionState)", view: "ConnectionsView")
        
        connectingComputer = computer
        
        // Failsafe: Clear connecting state if it hangs and show timeout error
        Task {
            try await Task.sleep(nanoseconds: 8_000_000_000) // 8 sec
            await MainActor.run {
                if self.connectingComputer?.id == computer.id {
                    viewLog("⚠️ Connection hung for 8 seconds, triggering timeout error", view: "ConnectionsView")
                    self.connectingComputer = nil
                    
                    // Trigger timeout error
                    let timeoutError = SSHError.timeout.formatError(displayName: computer.name)
                    self.connectionError = (timeoutError.title, timeoutError.message)
                    self.showingError = true
                    
                    // Clean up state
                    self.isAuthenticating = false
                    self.selectedConnection = nil
                    self.username = ""
                    self.password = ""
                }
            }
        }
        
        Task {
            do {
                // Always disconnect first to ensure fresh connection
                viewLog("Disconnecting any existing connection before attempting new one", view: "ConnectionsView")
                connectionManager.disconnect()
                
                // Small delay to ensure cleanup
                try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                
                try await connectionManager.verifyConnection(
                    host: computer.host,
                    username: username,
                    password: password
                )
                
                await MainActor.run {
                    viewLog("✓ ConnectionsView: Connection verified successfully", view: "ConnectionsView")
                    self.connectingComputer = nil  // Clear connecting state on success
                    self.tryConnect(computer: computer)
                }
                
            } catch {
                await MainActor.run {
                    viewLog("❌ ConnectionsView: Connection verification failed", view: "ConnectionsView")
                    viewLog("Error: \(error)", view: "ConnectionsView")
                    viewLog("Error type: \(type(of: error))", view: "ConnectionsView")
                    
                    // Clean up state on any error
                    self.isAuthenticating = false
                    self.connectingComputer = nil
                    
                    if let sshError = error as? SSHError {
                        viewLog("✅ Successfully cast to SSHError: \(sshError)", view: "ConnectionsView")
                        let formattedError = sshError.formatError(displayName: computer.name)
                        self.connectionError = (formattedError.title, formattedError.message)
                    } else {
                        viewLog("❌ Failed to cast to SSHError - using generic error", view: "ConnectionsView")
                        self.connectionError = (
                            "Connection Error",
                            """
                            An unexpected error occurred while connecting to \(computer.name).
                            
                            Technical details: \(error.localizedDescription)
                            """
                        )
                    }
                    self.showingError = true
                }
            }
        }
    }
    
    private func tryConnect(computer: Connection) {
        viewLog("ConnectionsView: Proceeding with connection flow", view: "ConnectionsView")
        
        // Show connection metadata without exposing sensitive info
        let isLocal = computer.host.contains(".local")
        let connectionType = isLocal ? "Bonjour (.local)" : "Manual IP"
        viewLog("Connection type: \(connectionType)", view: "ConnectionsView")
        viewLog("Computer name: \(String(computer.name.prefix(3)))***", view: "ConnectionsView")
        viewLog("Host: \(String(computer.host.prefix(3)))***", view: "ConnectionsView")
        viewLog("Has connected before: \(savedConnections.hasConnectedBefore(computer.host))", view: "ConnectionsView")
        
        selectedConnection = computer
        
        if !savedConnections.hasConnectedBefore(computer.host) {
            viewLog("First time setup needed - navigating to SetupFlowView", view: "ConnectionsView")
            showingSetupFlow = true
        } else {
            viewLog("Regular connection - navigating to ControlView", view: "ConnectionsView")
            navigateToControl = true
        }
        
        // Save connection info and preference
        viewLog("Saving connection info with saveCredentials: \(saveCredentials)", view: "ConnectionsView")
        savedConnections.add(
            hostname: computer.host,
            name: computer.name,
            username: username,
            password: saveCredentials ? password : nil,
            saveCredentials: saveCredentials
        )
        
        isAuthenticating = false
    }



    private func startNetworkScan() {
        viewLog("ConnectionsView: Starting network scan", view: "ConnectionsView")
        connections.removeAll()
        errorMessage = nil
        isSearching = true
        
        // Stop existing scan
        networkScanner?.cancel()
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        
        let scanner = NWBrowser(for: .bonjour(type: "_ssh._tcp.", domain: "local"), using: parameters)
        self.networkScanner = scanner
        
        scanner.stateUpdateHandler = { state in
            viewLog("Network scanner state: \(state)", view: "ConnectionsView")
            DispatchQueue.main.async {
                switch state {
                case .failed(let error):
                    viewLog("❌ Network scanner failed: \(error)", view: "ConnectionsView")
                    self.errorMessage = error.localizedDescription
                    self.isSearching = false
                case .ready:
                    viewLog("✓ Network scanner ready", view: "ConnectionsView")
                case .cancelled:
                    viewLog("Network scanner cancelled", view: "ConnectionsView")
                    self.isSearching = false
                case .setup:
                    viewLog("Network scanner setting up", view: "ConnectionsView")
                case .waiting:
                    viewLog("Network scanner waiting", view: "ConnectionsView")
                @unknown default:
                    viewLog("Network scanner in unknown state: \(state)", view: "ConnectionsView")
                }
            }
        }
        
        scanner.browseResultsChangedHandler = { results, changes in
            viewLog("Network scan found \(results.count) services", view: "ConnectionsView")
            DispatchQueue.main.async {
                self.connections = results.compactMap { result in
                    guard case .service(let name, let type, let domain, _) = result.endpoint else {
                        viewLog("Invalid endpoint format in scan result", view: "ConnectionsView")
                        return nil
                    }
                    
                    // Log connection metadata without exposing service name
                    viewLog("Found SSH service: type=\(type), domain=\(domain), name=\(String(name.prefix(3)))***", view: "ConnectionsView")
                    
                    let service = NetService(domain: domain, type: type, name: name)
                    service.resolve(withTimeout: 5.0)
                    
                    return service
                }
            }
        }
        
        viewLog("Starting network scan with 8 second timeout", view: "ConnectionsView")
        scanner.start(queue: .main)
        
        // Add timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            viewLog("Network scan timeout reached", view: "ConnectionsView")
            viewLog("Final service count: \(self.connections.count)", view: "ConnectionsView")
            scanner.cancel()
            DispatchQueue.main.async {
                self.isSearching = false
            }
        }
    }
}

#Preview {
    ConnectionsView()
}
