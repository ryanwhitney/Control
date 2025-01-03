import SwiftUI
import Foundation
import Network

struct ConnectionsView: View {
    @StateObject private var savedConnections = SavedConnections()
    @StateObject private var sshManager = SSHManager()
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var connections: [NetService] = []
    @State private var isAuthenticating = false
    @State private var selectedConnection: Connection?
    @State private var showingAddDialog = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var saveCredentials = false
    @State private var errorMessage: String?
    @State private var navigateToControl = false
    @State private var isSearching = false
    @State private var networkScanner: NWBrowser?
    @State private var connectingComputer: Connection?
    @State private var showingPreferences = false
    @State private var connectionError: (title: String, message: String)?
    @State private var showingError = false

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
            List {
                Section(header: Text("On Your Network".capitalized)) {
                    if isSearching {
                        HStack {
                            Text("Searching for connections...")
                                .foregroundColor(.secondary)
                            Spacer()
                            ProgressView()
                        }
                    } else if connections.isEmpty {
                        Text("No connections found")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(networkComputers) { computer in
                            ComputerRow(
                                computer: computer,
                                isConnecting: connectingComputer?.id == computer.id
                            ) {
                                selectComputer(computer)
                            }
                        }
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
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    savedConnections.remove(hostname: computer.host)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)

                                Button {
                                    selectedConnection = computer
                                    username = computer.lastUsername ?? ""
                                    password = "•••••"  // keep pass empty
                                    saveCredentials = false
                                    showingAddDialog = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let computer = savedComputers[index]
                                savedConnections.remove(hostname: computer.host)
                            }
                        }
                    }
                }
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
                        
                        Button(action: {
                            selectedConnection = nil
                            username = ""
                            password = ""
                            saveCredentials = true
                            showingAddDialog = true
                        }) {
                            Image(systemName: "plus")
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingPreferences = true
                    } label: {
                        Image(systemName: "gear")
                    }
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
                                tryConnect(computer: updatedComputer)
                            } else {
                                tryConnect(computer: computer)
                            }
                        },
                        onCancel: {
                            isAuthenticating = false
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
                        sshClient: sshManager.currentClient
                    )
                    .tint(preferences.tintColorValue)
                }
            }
            .sheet(isPresented: $showingPreferences) {
                PreferencesView()
            }
            .tint(preferences.tintColorValue)
        }
        .onAppear {
            startNetworkScan()
        }
        .onDisappear {
            networkScanner?.cancel()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                sshManager.disconnect()
            } else if scenePhase == .active {
                // Optionally reconnect if needed
            }
        }
        .alert(connectionError?.title ?? "", isPresented: $showingError, presenting: connectionError) { _ in
            Button("OK") {
                showingError = false
            }
        } message: { error in
            Text(error.message)
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
                    
                    if isConnecting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
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
                name: service.name.replacingOccurrences(of: "\\032", with: " "),
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
        connectingComputer = computer
        username = computer.lastUsername ?? ""
        password = ""  // Reset password
        saveCredentials = true  // Default to true
        
        if let savedUsername = computer.lastUsername,
           let savedPassword = savedConnections.password(for: computer.host) {
            // We have complete saved credentials, try connecting
            username = savedUsername
            password = savedPassword
            tryConnect(computer: computer, showAuthOnFail: true)
        } else {
            // Missing some credentials, show auth view
            connectingComputer = nil
            isAuthenticating = true
        }
    }
    
    private func tryConnect(computer: Connection, showAuthOnFail: Bool = false) {
        print("\n=== Connection Attempt ===")
        print("Computer: \(computer.name) (\(computer.host))")
        print("Username: \(username)")
        print("Has Password: \(!password.isEmpty)")
        print("Save Credentials: \(saveCredentials)")
        
        // Add state to track if we've already handled a response
        var hasHandledResponse = false
        
        sshManager.connect(host: computer.host, username: username, password: password) { result in
            DispatchQueue.main.async {
                // Guard against multiple callbacks
                guard !hasHandledResponse else { return }
                hasHandledResponse = true
                
                self.connectingComputer = nil
                switch result {
                case .success:
                    print("✅ Connection successful")
                    if self.saveCredentials {
                        self.savedConnections.updateLastUsername(
                            for: computer.host,
                            name: computer.name,
                            username: self.username,
                            password: self.password
                        )
                    } else {
                        self.savedConnections.updateLastUsername(
                            for: computer.host,
                            name: computer.name,
                            username: self.username
                        )
                    }
                    self.selectedConnection = computer
                    self.navigateToControl = true
                    self.isAuthenticating = false
                    
                case .failure(let error):
                    print("❌ Connection failed")
                    print("Error: \(error)")
                    
                    // Always close the auth view if it's open
                    self.isAuthenticating = false
                    
                    if let sshError = error as? SSHError {
                        switch sshError {
                        case .authenticationFailed:
                            print("Authentication failed - showing error")
                            self.connectionError = (
                                "Authentication Failed",
                                """
                                The username or password provided was incorrect.
                                Please check your credentials and try again.
                                
                                Technical details: Authentication failed
                                """
                            )
                            self.showingError = true
                            
                        case .connectionFailed(let reason):
                            print("Connection failed: \(reason)")
                            self.connectionError = (
                                "Connection Failed",
                                """
                                \(reason)
                                
                                Please check that:
                                • The computer is turned on
                                • You're on the same network
                                • Remote Login is enabled in System Settings
                                
                                Technical details: Connection failed
                                """
                            )
                            self.showingError = true
                            
                        case .timeout:
                            print("Connection timed out")
                            self.connectionError = (
                                "Connection Timeout",
                                """
                                The connection to \(computer.name) timed out.
                                Please check your network connection and ensure the computer is reachable.
                                
                                Technical details: Connection attempt timed out after 5 seconds
                                """
                            )
                            self.showingError = true
                            
                        case .channelError(let details):
                            print("Channel error: \(details)")
                            self.connectionError = (
                                "Connection Error",
                                """
                                Failed to establish a secure connection with \(computer.name).
                                Please try again in a few moments.
                                
                                Technical details: \(details)
                                """
                            )
                            self.showingError = true
                            
                        case .channelNotConnected:
                            print("Channel not connected")
                            self.connectionError = (
                                "Connection Error",
                                """
                                Could not establish a connection with \(computer.name).
                                Please ensure Remote Login is enabled and try again.
                                
                                Technical details: SSH channel not connected
                                """
                            )
                            self.showingError = true
                            
                        case .invalidChannelType:
                            print("Invalid channel type")
                            self.connectionError = (
                                "Connection Error",
                                """
                                An internal error occurred while connecting to \(computer.name).
                                Please try again.
                                
                                Technical details: Invalid SSH channel type
                                """
                            )
                            self.showingError = true
                        }
                    } else {
                        print("Unknown error: \(error)")
                        self.connectionError = (
                            "Connection Error",
                            """
                            An unexpected error occurred while connecting to \(computer.name).
                            Please try again.
                            
                            Technical details: \(error.localizedDescription)
                            """
                        )
                        self.showingError = true
                    }
                }
            }
        }
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
                default:
                    break
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

class SSHManager: ObservableObject {
    private var client = SSHClient()
    private var isConnected = false
    
    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // cleanup  before new connection
        disconnect()
        
        // new client if needed
        if !isConnected {
            client = SSHClient()
        }
        
        client.connect(host: host, username: username, password: password) { result in
            switch result {
            case .success:
                self.isConnected = true
            case .failure:
                self.isConnected = false
            }
            completion(result)
        }
    }
    
    func disconnect() {
        client = SSHClient()  // create fresh client, old one gets deallocated
        isConnected = false
    }
    
    func executeCommand(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        client.executeCommandWithNewChannel(command, completion: completion)
    }
    
    var currentClient: SSHClient {
        return client
    }
    
    deinit {
        disconnect()
    }
}

struct ComputerListView_Previews: PreviewProvider {
    static var previews: some View {
        ConnectionsView()
    }
}

struct ComputerListView_Previews_settings: PreviewProvider {
    @State private var showingPreferences = true

    static var previews: some View {
        ConnectionsView()
    }
}
