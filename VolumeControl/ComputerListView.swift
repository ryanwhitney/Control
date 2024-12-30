import SwiftUI
import Foundation
import Network

struct ComputerListView: View {
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
    private let browser = NetServiceBrowser()

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
                ForEach(allComputers) { computer in
                    Button(action: { selectComputer(computer) }) {
                        VStack(alignment: .leading) {
                            Text(computer.name)
                                .font(.headline)
                            Text(computer.host)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            if let username = computer.lastUsername {
                                Text(username)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Computers")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: refreshComputers) {
                            Image(systemName: "arrow.clockwise")
                        }
                        
                        Button(action: { showingAddDialog = true }) {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddDialog) {
                AddComputerView { host, username, password in
                    addManualComputer(host, username: username, password: password)
                    showingAddDialog = false
                }
            }
            .sheet(isPresented: $isAuthenticating) {
                if let computer = selectedComputer {
                    AuthenticationView(
                        name: computer.name,
                        username: $username,
                        password: $password,
                        saveCredentials: $saveCredentials,
                        onSuccess: {
                            tryConnect(computer: computer)
                        },
                        onCancel: {
                            isAuthenticating = false
                        }
                    )
                }
            }
            .navigationDestination(isPresented: $navigateToControl) {
                if let computer = selectedComputer {
                    VolumeControlView(
                        host: computer.host,
                        username: username,
                        password: password,
                        sshClient: sshManager.currentClient
                    )
                }
            }
        }
        .onAppear {
            refreshComputers()
        }
        .onDisappear {
            browser.stop()
        }
        // Handle app lifecycle
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                sshManager.disconnect()
            case .active:
                // Optionally reconnect if needed
                break
            default:
                break
            }
        }
    }

    private var allComputers: [Computer] {
        var result = Set<Computer>()
        
        // Add Bonjour computers
        result.formUnion(computers.compactMap { service in
            guard let host = service.hostName else { return nil }
            return Computer(
                id: host,
                name: service.name,
                host: host,
                type: .bonjour(service),
                lastUsername: savedConnections.lastUsername(for: host)
            )
        })
        
        // Add manual computers
        result.formUnion(savedConnections.items.map { saved in
            Computer(
                id: saved.hostname,
                name: saved.name ?? saved.hostname,
                host: saved.hostname,
                type: .manual,
                lastUsername: saved.username
            )
        })
        
        return Array(result).sorted { $0.name < $1.name }
    }

    private func selectComputer(_ computer: Computer) {
        selectedComputer = computer
        username = computer.lastUsername ?? ""
        password = ""  // Reset password
        saveCredentials = false  // Reset save credentials toggle
        
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
                        self.savedConnections.updateLastUsername(for: computer.host, username: self.username, password: self.password)
                    } else {
                        self.savedConnections.updateLastUsername(for: computer.host, username: self.username)
                    }
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

    private func addManualComputer(_ host: String, username: String? = nil, password: String? = nil) {
        savedConnections.add(hostname: host, username: username, password: password)
    }

    func refreshComputers() {
        computers.removeAll()
        errorMessage = nil
        
        // Stop any existing search
        browser.stop()
        
        // Create new delegate and start search
        let delegate = BonjourDelegate(computers: $computers, errorMessage: $errorMessage)
        browser.delegate = delegate
        browser.searchForServices(ofType: "_ssh._tcp.", inDomain: "local.")
    }
}

// Add Computer view with credential options
struct AddComputerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hostname = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saveCredentials = false
    let onAdd: (String, String?, String?) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Computer")) {
                    TextField("Hostname or IP", text: $hostname)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                
                Section(header: Text("Credentials (Optional)")) {
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    
                    Toggle("Save credentials for one-tap login", isOn: $saveCredentials)
                }
                
                Section {
                    Button("Add") {
                        onAdd(hostname, 
                             username.isEmpty ? nil : username,
                             saveCredentials ? password : nil)
                    }
                    .disabled(hostname.isEmpty)
                }
            }
            .navigationTitle("Add Computer")
            .navigationBarItems(trailing: Button("Cancel") {
                dismiss()
            })
        }
    }
}

class BonjourDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Binding var computers: [NetService]
    @Binding var errorMessage: String?
    
    init(computers: Binding<[NetService]>, errorMessage: Binding<String?>) {
        _computers = computers
        _errorMessage = errorMessage
        super.init()
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5)
    }
    
    func netServiceDidResolveAddress(_ sender: NetService) {
        DispatchQueue.main.async { [weak self] in
            if !(self?.computers.contains(where: { $0.name == sender.name }) ?? false) {
                self?.computers.append(sender)
            }
        }
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = "Failed to search: \(errorDict)"
        }
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = "Failed to resolve: \(errorDict)"
        }
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
        ComputerListView()
    }
}
