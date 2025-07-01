import SwiftUI
import Foundation

@MainActor
class ConnectionsViewModel: ObservableObject {
    @Published var selectedConnection: Connection?
    @Published var connectingComputer: Connection?
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var saveCredentials = false
    @Published var isAuthenticating = false
    @Published var connectionError: (title: String, message: String)?
    @Published var showingAddDialog = false
    @Published var showingError = false
    @Published var showingSetupFlow = false
    @Published var navigateToControl = false
    @Published var activePopover: ActivePopover?
    @Published var showingWhatsNew = false
    
    @Published private(set) var networkComputers: [Connection] = []
    @Published private(set) var savedComputers: [Connection] = []
    @Published private(set) var isSearching = false
    
    private let savedConnections = SavedConnections()
    private let connectionManager = SSHConnectionManager.shared
    private let preferences = UserPreferences.shared
    private let networkScanner = NetworkScanner()
    
    enum ActivePopover: Identifiable {
        case help
        case preferences
        var id: Self { self }
    }
    
    var hasConnections: Bool {
        !networkComputers.isEmpty || !savedComputers.isEmpty
    }
    

    
    init() {
        isSearching = networkScanner.isScanning
        updateComputerLists()
        setupObservers()
    }
    
    private func setupObservers() {
        networkScanner.$services
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNetworkComputers()
            }
            .store(in: &cancellables)
        
        networkScanner.$isScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isScanning in
                self?.isSearching = isScanning
            }
            .store(in: &cancellables)
        
        savedConnections.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateSavedComputers()
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    func startNetworkScan() {
        networkScanner.startScan()
        isSearching = networkScanner.isScanning
    }
    
    func selectComputer(_ computer: Connection) {
        guard connectingComputer == nil else { return }
        
        selectedConnection = computer
        
        if let savedConnection = savedConnections.items.first(where: { $0.hostname == computer.host }) {
            username = savedConnection.username ?? ""
            let retrievedPassword = savedConnections.password(for: computer.host)
            password = retrievedPassword ?? ""
            saveCredentials = savedConnections.getSaveCredentialsPreference(for: computer.host)
            
            if !username.isEmpty && !password.isEmpty {
                connectWithCredentials(computer: computer)
            } else {
                isAuthenticating = true
            }
        } else {
            username = computer.lastUsername ?? ""
            password = ""
            saveCredentials = savedConnections.getSaveCredentialsPreference(for: computer.host)
            isAuthenticating = true
        }
    }
    
    func connectWithCredentials(computer: Connection) {
        viewLog("ConnectionsViewModel: Attempting connection with saved credentials", view: "ConnectionsViewModel")
        
        logConnectionAttempt(computer: computer)
        connectingComputer = computer
        
        Task {
            do {
                try await performConnection(computer: computer)
                connectingComputer = nil
                navigateToApp(computer: computer)
            } catch {
                connectingComputer = nil
                handleConnectionError(error: error, computer: computer)
            }
        }
    }
    
    func connectWithNewCredentials(computer: Connection) {
        viewLog("ConnectionsViewModel: Attempting connection with new credentials", view: "ConnectionsViewModel")
        
        logConnectionAttempt(computer: computer)
        connectingComputer = computer
        
        Task {
            do {
                try await performConnection(computer: computer)
                connectingComputer = nil
                
                viewLog("Saving credentials after successful verification with saveCredentials: \(saveCredentials)", view: "ConnectionsViewModel")
                savedConnections.add(
                    hostname: computer.host,
                    name: computer.name,
                    username: username,
                    password: saveCredentials ? password : nil,
                    saveCredentials: saveCredentials
                )
                
                navigateToApp(computer: computer)
            } catch {
                connectingComputer = nil
                handleConnectionError(error: error, computer: computer)
            }
        }
    }
    
    func deleteConnection(hostname: String) {
        savedConnections.remove(hostname: hostname)
    }
    
    func editConnection(_ computer: Connection) {
        selectedConnection = computer
        username = computer.lastUsername ?? ""
        let existingPassword = savedConnections.password(for: computer.host)
        password = existingPassword != nil ? "•••••" : ""
        saveCredentials = savedConnections.getSaveCredentialsPreference(for: computer.host)
        showingAddDialog = true
    }
    
    func updateCredentials(hostname: String, name: String?, username: String, password: String?, saveCredentials: Bool) {
        let passwordToSave: String?
        if saveCredentials {
            passwordToSave = password == "•••••" ? savedConnections.password(for: hostname) : password
        } else {
            passwordToSave = nil
        }
        
        savedConnections.updateLastUsername(
            for: hostname,
            name: name,
            username: username,
            password: passwordToSave,
            saveCredentials: saveCredentials
        )
    }
    
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        connectionManager.handleScenePhaseChange(from: oldPhase, to: newPhase)
    }
    
    func onAppear() {
        connectionManager.disconnect()
        
        // Auto-scan only if we haven't scanned recently
        if networkScanner.shouldAutoScan {
            viewLog("Auto-starting network scan (last scan >30s ago)", view: "ConnectionsViewModel")
            startNetworkScan()
        } else {
            viewLog("Skipping auto-scan (scanned recently)", view: "ConnectionsViewModel")
        }
        
        if preferences.shouldShowWhatsNew {
            Task {
                try await Task.sleep(nanoseconds: 500_000_000)
                showingWhatsNew = true
            }
        }
    }
    
    func onDisappear() {
        networkScanner.stopScan()
        isSearching = networkScanner.isScanning
    }
    
    private func performConnection(computer: Connection) async throws {
        viewLog("Disconnecting any existing connection before attempting new one", view: "ConnectionsViewModel")
        connectionManager.disconnect()
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        try await connectionManager.verifyConnection(
            host: computer.host,
            username: username,
            password: password
        )
        
        viewLog("✓ ConnectionsViewModel: Connection verified successfully", view: "ConnectionsViewModel")
    }
    
    private func handleConnectionError(error: Error, computer: Connection) {
        isAuthenticating = false
        
        if let sshError = error as? SSHError {
            viewLog("✅ Successfully handled SSHError: \(sshError)", view: "ConnectionsViewModel")
            let formattedError = sshError.formatError(displayName: computer.name)
            connectionError = (formattedError.title, formattedError.message)
        } else {
            viewLog("❌ Handling generic error", view: "ConnectionsViewModel")
            connectionError = (
                "Connection Error",
                """
                An unexpected error occurred while connecting to \(computer.name).
                
                Technical details: \(error.localizedDescription)
                """
            )
        }
        showingError = true
    }
    
    private func navigateToApp(computer: Connection) {
        viewLog("ConnectionsViewModel: Navigating to app", view: "ConnectionsViewModel")
        
        selectedConnection = computer
        
        if !savedConnections.hasConnectedBefore(computer.host) {
            viewLog("First time setup needed - navigating to SetupFlowView", view: "ConnectionsViewModel")
            showingSetupFlow = true
        } else {
            viewLog("Regular connection - navigating to ControlView", view: "ConnectionsViewModel")
            navigateToControl = true
        }
        
        isAuthenticating = false
    }
    
    private func logConnectionAttempt(computer: Connection) {
        let isLocal = computer.host.contains(".local")
        let connectionType = isLocal ? "Bonjour (.local)" : "Manual IP"
        viewLog("Connection type: \(connectionType)", view: "ConnectionsViewModel")
        viewLog("Computer name: \(String(computer.name.prefix(3)))***", view: "ConnectionsViewModel")
        viewLog("Host: \(String(computer.host.prefix(3)))***", view: "ConnectionsViewModel")
    }
    
    private func updateComputerLists() {
        updateNetworkComputers()
        updateSavedComputers()
    }
    
    private func updateNetworkComputers() {
        networkComputers = networkScanner.services.compactMap { service in
            Connection.fromNetService(service, lastUsername: savedConnections.lastUsername(for: service.hostName?.replacingOccurrences(of: ".local.", with: ".local") ?? ""))
        }
    }
    
    private func updateSavedComputers() {
        savedComputers = savedConnections.items
            .map(Connection.fromSavedConnection)
            .sorted { $0.name < $1.name }
    }
}

import Combine 