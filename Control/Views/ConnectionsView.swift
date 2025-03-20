import SwiftUI
import Foundation
import Network

struct ConnectionsView: View {
    @StateObject private var savedConnections = SavedConnections()
    @StateObject private var connectionManager = SSHConnectionManager()
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
    @State private var showingFirstTimeSetup = false
    @State private var navigateToPermissions = false
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
                                            password = "•••••"
                                            saveCredentials = false
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
                            savedConnections.updateLastUsername(
                                for: computer.host,
                                name: nickname ?? computer.name,
                                username: username,
                                password: saveCredentials ? password : nil
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
                            addManualComputer(hostname, name: nickname ?? hostname, username: username, password: password)
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
            .navigationDestination(isPresented: $showingFirstTimeSetup) {
                if let computer = selectedConnection {
                    ChooseAppsView(
                        host: computer.host,
                        displayName: computer.name,
                        username: username,
                        password: password,
                        onComplete: { selectedPlatforms in
                            savedConnections.updateEnabledPlatforms(computer.host, platforms: selectedPlatforms)
                            showingFirstTimeSetup = false
                            navigateToPermissions = true
                        }
                    )
                }
            }
            .navigationDestination(isPresented: $navigateToPermissions) {
                if let computer = selectedConnection {
                    PermissionsView(
                        host: computer.host,
                        displayName: computer.name,
                        username: username,
                        password: password,
                        enabledPlatforms: savedConnections.enabledPlatforms(computer.host),
                        onComplete: {
                            savedConnections.markAsConnected(computer.host)
                            navigateToPermissions = false
                            navigateToControl = true
                        }
                    )
                }
            }
            .navigationDestination(isPresented: $navigateToControl) {
                if let computer = selectedConnection {
                    ControlView(
                        host: computer.host,
                        displayName: computer.name,
                        username: username,
                        password: password,
                        enabledPlatforms: savedConnections.enabledPlatforms(computer.host)
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
        .onChange(of: showingFirstTimeSetup) { _, newValue in
            if !newValue {
                // Reset states when returning from setup
                connectingComputer = nil
            }
        }
        .onChange(of: navigateToPermissions) { _, newValue in
            if !newValue {
                // Reset states when returning from permissions
                connectingComputer = nil
            }
        }
        .onChange(of: showingError) { _, newValue in
            if newValue {
                // Reset states when showing error
                connectingComputer = nil
                selectedConnection = nil
            }
        }
    }

    // Separate computer row view for reuse
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
                saveCredentials = true
                isAuthenticating = true
            }
        } else {
            // Show authentication dialog for new connection
            username = computer.lastUsername ?? ""
            password = ""
            saveCredentials = true
            isAuthenticating = true
        }
    }
    
    private func verifyAndConnect(computer: Connection) {
        print("\n=== ConnectionsView: Verifying connection ===")
        print("Computer: \(computer.name) (\(computer.host))")
        
        connectingComputer = computer
        
        Task {
            do {
                try await connectionManager.verifyConnection(
                    host: computer.host,
                    username: username,
                    password: password
                )
                
                await MainActor.run {
                    self.tryConnect(computer: computer)
                }
            } catch {
                await MainActor.run {
                    self.isAuthenticating = false
                    self.connectingComputer = nil
                    
                    if let sshError = error as? SSHError {
                        let formattedError = sshError.formatError(displayName: computer.name)
                        self.connectionError = (formattedError.title, formattedError.message)
                    } else {
                        self.connectionError = (
                            "Connection Error",
                            """
                            An unexpected error occurred while connecting to \(computer.name).
                            """
                        )
                    }
                    self.showingError = true
                }
            }
        }
    }
    
    private func tryConnect(computer: Connection) {
        print("\n=== ConnectionsView: Proceeding with connection ===")
        print("Computer: \(computer.name) (\(computer.host))")
        
        selectedConnection = computer
        
        if !savedConnections.hasConnectedBefore(computer.host) {
            print("First time setup needed")
            showingFirstTimeSetup = true
        } else {
            print("Regular connection")
            navigateToControl = true
        }
        
        // Save credentials if requested
        if saveCredentials {
            savedConnections.add(
                hostname: computer.host,
                name: computer.name,
                username: username,
                password: password
            )
        } else {
            // Just update the username without password
            savedConnections.updateLastUsername(
                for: computer.host,
                name: computer.name,
                username: username
            )
        }
        
        isAuthenticating = false
    }

    private func addManualComputer(_ host: String, name: String, username: String? = nil, password: String? = nil) {
        savedConnections.add(hostname: host, username: username, password: password)
    }

    private func startNetworkScan() {
        print("\n=== Starting Network Scan ===")
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
            print("Scanner state: \(state)")
            DispatchQueue.main.async {
                switch state {
                case .failed(let error):
                    print("Scanner failed: \(error)")
                    self.errorMessage = error.localizedDescription
                    self.isSearching = false
                case .ready:
                    print("Scanner ready")
                case .cancelled:
                    print("Scanner cancelled")
                    self.isSearching = false
                case .setup:
                    print("Scanner setting up")
                case .waiting:
                    print("Scanner waiting")
                @unknown default:
                    print("Scanner in unknown state: \(state)")
                }
            }
        }
        
        scanner.browseResultsChangedHandler = { results, changes in
            print("Found \(results.count) services")
            DispatchQueue.main.async {
                self.connections = results.compactMap { result in
                    guard case .service(let name, let type, let domain, _) = result.endpoint else {
                        print("Invalid endpoint format")
                        return nil
                    }
                    print("Found service: \(name)")
                    
                    let service = NetService(domain: domain, type: type, name: name)
                    service.resolve(withTimeout: 5.0)
                    
                    // Print detailed service information
                    print("Service details:")
                    print("  - Name: \(service.name)")
                    print("  - Type: \(service.type)")
                    print("  - Domain: \(service.domain)")
                    print("  - HostName: \(service.hostName ?? "unknown")")
                    if let addresses = service.addresses {
                        print("  - Addresses: \(addresses.count) found")
                        for (index, address) in addresses.enumerated() {
                            print("    [\(index)] \(address.description)")
                        }
                    }
                    print("  - Port: \(service.port)")
                    
                    return service
                }
            }
        }
        
        print("Starting network scan...")
        scanner.start(queue: .main)
        
        // Add timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            print("\n=== Scan Complete ===")
            print("Final computer count: \(self.connections.count)")
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
