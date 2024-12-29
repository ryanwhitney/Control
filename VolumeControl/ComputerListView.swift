import SwiftUI
import Foundation
import Network

struct ComputerListView: View {
    @StateObject private var savedConnections = SavedConnections()
    @State private var computers: [NetService] = []
    @State private var isAuthenticating = false
    @State private var selectedComputer: Computer?
    @State private var showingAddDialog = false
    @State private var username: String = ""
    @State private var password: String = ""
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
                AddComputerView { host in
                    addManualComputer(host)
                    showingAddDialog = false
                }
            }
            .sheet(isPresented: $isAuthenticating) {
                if let computer = selectedComputer {
                    AuthenticationView(
                        name: computer.name,
                        username: $username,
                        password: $password,
                        onSuccess: {
                            savedConnections.updateLastUsername(for: computer.host, username: username)
                            navigateToControl = true
                            isAuthenticating = false
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
                        password: password
                    )
                }
            }
        }
        .onAppear {
            refreshComputers()
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
        isAuthenticating = true
    }

    private func addManualComputer(_ host: String) {
        savedConnections.add(hostname: host)
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

// Simplified Add Computer view
struct AddComputerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hostname = ""
    let onAdd: (String) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                TextField("Hostname or IP", text: $hostname)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                
                Button("Add") {
                    onAdd(hostname)
                }
                .disabled(hostname.isEmpty)
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



struct ComputerListView_Previews: PreviewProvider {
    static var previews: some View {
        ComputerListView()
    }
}
