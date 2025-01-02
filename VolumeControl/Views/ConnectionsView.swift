import SwiftUI
import Foundation
import Network

struct ConnectionsView: View {
    @StateObject private var savedConnections = SavedConnections()
    @StateObject private var sshManager = SSHManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var computers: [NetService] = []
    @State private var isAuthenticating = false
    @State private var selectedComputer: Computer?
    @State private var showingAddDialog = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var saveCredentials = false
    @State private var errorMessage: String?
    @State private var navigateToControl = false
    @State private var isSearching = false
    @State private var browser: NWBrowser?

    struct Computer: Identifiable, Hashable {
        let id: String
        let name: String
        let host: String
        let type: ComputerType
        var lastUsername: String?
        
        enum ComputerType {
            case bonjour(NetService)
            case manual
        }
        
        static func == (lhs: Computer, rhs: Computer) -> Bool {
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
                    } else if computers.isEmpty {
                        Text("No connections found")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(networkComputers) { computer in
                            ComputerRow(computer: computer) {
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
                            ComputerRow(computer: computer) {
                                selectComputer(computer)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    savedConnections.remove(hostname: computer.host)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                
                                Button {
                                    selectedComputer = computer
                                    username = computer.lastUsername ?? ""
                                    password = ""  // Don't show saved password
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
                    startBrowsing()
                    // Wait for the browser timeout (8 seconds) before completing the refresh
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
                    .accessibilityAddTraits(.isHeader) // Ensure it's recognized as a header

                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: startBrowsing) {
                            Image(systemName: "arrow.clockwise")
                        }
                        
                        Button(action: {
                            // Clear all state before showing add dialog
                            selectedComputer = nil
                            username = ""
                            password = ""
                            saveCredentials = true  // Keep this true as it's our default
                            showingAddDialog = true
                        }) {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddDialog) {
                if let computer = selectedComputer {
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
                            selectedComputer = nil
                        },
                        onCancel: {
                            showingAddDialog = false
                            selectedComputer = nil
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
                if let computer = selectedComputer {
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
                                let updatedComputer = Computer(
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
                if let computer = selectedComputer {
                    ControlView(
                        host: computer.host,
                        displayName: computer.name,
                        username: username,
                        password: password,
                        sshClient: sshManager.currentClient
                    )
                }
            }
        }
        .onAppear {
            startBrowsing()
        }
        .onDisappear {
            browser?.cancel()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                sshManager.disconnect()
            } else if scenePhase == .active {
                // Optionally reconnect if needed
            }
        }
    }

    // Separate computer row view for reuse
    struct ComputerRow: View {
        let computer: Computer
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
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
            }
        }
    }

    private var networkComputers: [Computer] {
        computers.compactMap { service in
            guard let hostname = service.hostName else { return nil }
            
            // Clean up the hostname by removing the extra period
            let cleanHostname = hostname.replacingOccurrences(of: ".local.", with: ".local")
            
            return Computer(
                id: service.name,
                name: service.name.replacingOccurrences(of: "\\032", with: " "),
                host: cleanHostname,
                type: .bonjour(service),
                lastUsername: savedConnections.lastUsername(for: cleanHostname)
            )
        }
    }
    
    private var savedComputers: [Computer] {
        savedConnections.items.map { saved in
            Computer(
                id: saved.hostname,
                name: saved.name ?? saved.hostname,
                host: saved.hostname,
                type: .manual,
                lastUsername: saved.username
            )
        }.sorted { $0.name < $1.name }
    }

    private func selectComputer(_ computer: Computer) {
        selectedComputer = computer
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
            isAuthenticating = true
        }
    }
    
    private func tryConnect(computer: Computer, showAuthOnFail: Bool = false) {
        sshManager.connect(host: computer.host, username: username, password: password) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    if self.saveCredentials {
                        self.savedConnections.updateLastUsername(
                            for: computer.host,
                            name: computer.name,  // Use the current name from the computer object
                            username: self.username,
                            password: self.password
                        )
                    } else {
                        self.savedConnections.updateLastUsername(
                            for: computer.host,
                            name: computer.name,  // Add name here too
                            username: self.username
                        )
                    }
                    self.selectedComputer = computer
                    self.navigateToControl = true
                    self.isAuthenticating = false
                case .failure(let error):
                    print("Connection failed: \(error)")
                    if showAuthOnFail {
                        self.password = ""
                        self.isAuthenticating = true
                    }
                }
            }
        }
    }

    private func addManualComputer(_ host: String, name: String, username: String? = nil, password: String? = nil) {
        savedConnections.add(hostname: host, username: username, password: password)
    }

    private func startBrowsing() {
        print("\n=== Starting Network Discovery ===")
        computers.removeAll()
        errorMessage = nil
        isSearching = true
        
        // Stop existing browser
        browser?.cancel()
        
        // Create new browser
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp.", domain: "local"), using: parameters)
        self.browser = browser
        
        browser.stateUpdateHandler = { state in
            print("Browser state: \(state)")
            DispatchQueue.main.async {
                switch state {
                case .failed(let error):
                    print("Browser failed: \(error)")
                    self.errorMessage = error.localizedDescription
                    self.isSearching = false
                case .ready:
                    print("Browser ready")
                case .cancelled:
                    print("Browser cancelled")
                    self.isSearching = false
                default:
                    break
                }
            }
        }
        
        browser.browseResultsChangedHandler = { results, changes in
            print("Found \(results.count) services")
            DispatchQueue.main.async {
                self.computers = results.compactMap { result in
                    guard case .service(let name, let type, let domain, let endpoint) = result.endpoint else {
                        print("Invalid endpoint format")
                        return nil
                    }
                    print("Found service: \(name)")
                    print("Endpoint details: \(String(describing: endpoint))")
                    
                    // Create NetService and start resolution
                    let service = NetService(domain: domain, type: type, name: name)
                    service.resolve(withTimeout: 5.0)
                    return service
                }
            }
        }
        
        print("Starting browser...")
        browser.start(queue: .main)
        
        // Add timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            print("\n=== Search Complete ===")
            print("Final computer count: \(self.computers.count)")
            browser.cancel()
            DispatchQueue.main.async {
                self.isSearching = false
            }
        }
    }
}

class BonjourDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Binding var computers: [NetService]
    @Binding var errorMessage: String?
    private var resolving: Set<String> = []
    
    init(computers: Binding<[NetService]>, errorMessage: Binding<String?>) {
        _computers = computers
        _errorMessage = errorMessage
        super.init()
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let serviceName = service.name.replacingOccurrences(of: "\\032", with: " ")
        print("Found service: \(serviceName)")
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }
    
    func netServiceDidResolveAddress(_ sender: NetService) {
        let serviceName = sender.name.replacingOccurrences(of: "\\032", with: " ")
        print("Resolved service: \(serviceName) host: \(sender.hostName ?? "unknown")")
        
        DispatchQueue.main.async {
            if !self.computers.contains(where: { $0.name == serviceName }),
               sender.hostName != nil {
                self.computers.append(sender)
            }
        }
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        print("Search error: \(errorDict)")
    }
}

// Update SSH Manager to handle its own client state
class SSHManager: ObservableObject {
    private var client = SSHClient()
    private var isConnected = false
    
    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // Ensure clean state before new connection
        disconnect()
        
        // Create new client if needed
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
        client = SSHClient()  // Create fresh client, old one will be deallocated
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
