import SwiftUI
import Foundation
import Combine

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

    @Published var networkComputers: [Connection] = []
    @Published var savedComputers: [Connection] = []
    @Published var isSearching = false
    @Published var showProgressIndicator = false

    private var currentScanResults: [Connection] = []
    private var scanStartTime: Date?
    private var scanCompletionTimer: Timer?
    private var scanUpdateTimer: Timer?

    private let savedConnections = SavedConnections()
    private let connectionManager = SSHConnectionManager.shared
    private let preferences = UserPreferences.shared
    private let networkScanner = NetworkScanner()
    private var cancellables = Set<AnyCancellable>()

    enum ActivePopover: Identifiable {
        case help
        case preferences
        var id: Self { self }
    }

    var hasConnections: Bool {
        !networkComputers.isEmpty || !savedComputers.isEmpty
    }

    init() {
        viewLog("ConnectionsViewModel init starting", view: "ConnectionsViewModel")

        // Initialize saved computers first
        updateSavedComputers()
        viewLog("Init: saved computers count: \(savedComputers.count)", view: "ConnectionsViewModel")

        // Set initial scanning state
        isSearching = networkScanner.isScanning
        viewLog("Init: scanner.isScanning: \(networkScanner.isScanning), services count: \(networkScanner.services.count)", view: "ConnectionsViewModel")

        // Initialize network computers - process any existing scanner results
        updateNetworkComputersStably()
        viewLog("Init: network computers count after update: \(networkComputers.count)", view: "ConnectionsViewModel")

        setupObservers()

        // If scanner has existing results but isn't scanning, ensure they get loaded
        if !networkScanner.services.isEmpty && !isSearching {
            viewLog("Initializing with existing scanner results", view: "ConnectionsViewModel")
            updateNetworkComputersStably()
        }

        viewLog("ConnectionsViewModel init completed - networkComputers: \(networkComputers.count), isSearching: \(isSearching)", view: "ConnectionsViewModel")
    }

    private func setupObservers() {
        networkScanner.$services
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNetworkComputersStably()
            }
            .store(in: &cancellables)

        // Simplified scanning state management
        networkScanner.$isScanning
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] isScanning in
                self?.handleScanningStateChange(isScanning)
            }
            .store(in: &cancellables)

        savedConnections.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateSavedComputers()
            }
            .store(in: &cancellables)
    }

    func startNetworkScan() {
        viewLog("startNetworkScan called - isSearching: \(isSearching)", view: "ConnectionsViewModel")

        // Don't start a new scan if one is already in progress
        guard !isSearching else {
            viewLog("NetworkScan: Ignoring scan request - already scanning", view: "ConnectionsViewModel")
            return
        }

        viewLog("NetworkScan: Starting new scan via networkScanner.startScan()", view: "ConnectionsViewModel")
        networkScanner.startScan()
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

        viewLog("onAppear called - starting network scan", view: "ConnectionsViewModel")

        // Always scan on app launch unless already scanning
        if !isSearching {
            viewLog("Starting network scan on app launch", view: "ConnectionsViewModel")
            startNetworkScan()
        } else {
            viewLog("Skipping scan - already scanning", view: "ConnectionsViewModel")
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
        showProgressIndicator = false
        cleanupTimers()
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
        viewLog("⛵︎ Navigating to app", view: "ConnectionsViewModel")

        selectedConnection = computer

        if !savedConnections.hasConnectedBefore(computer.host) {
            viewLog("⎈ First time setup needed - navigating to SetupFlowView", view: "ConnectionsViewModel")
            showingSetupFlow = true
        } else {
            viewLog("⛵︎ navigating to ControlView", view: "ConnectionsViewModel")
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

    private func updateNetworkComputersStably() {
        // Convert scanner services to connections
        currentScanResults = networkScanner.services.compactMap { service in
            Connection.fromNetService(service, lastUsername: savedConnections.lastUsername(for: service.hostName?.replacingOccurrences(of: ".local.", with: ".local") ?? ""))
        }

        // Create a new array to batch all changes
        var updatedNetworkComputers = networkComputers

        // Add new connections
        for scanResult in currentScanResults {
            if !updatedNetworkComputers.contains(where: { $0.host == scanResult.host }) {
                viewLog("NetworkScan: Adding new connection: \(scanResult.name)", view: "ConnectionsViewModel")
                updatedNetworkComputers.append(scanResult)
            }
        }

        // Update existing connections (for lastUsername changes)
        for i in 0..<updatedNetworkComputers.count {
            if let updatedConnection = currentScanResults.first(where: { $0.host == updatedNetworkComputers[i].host }) {
                if updatedNetworkComputers[i].lastUsername != updatedConnection.lastUsername {
                    updatedNetworkComputers[i] = updatedConnection
                }
            }
        }

        // Apply all changes atomically to prevent UI flickering
        networkComputers = updatedNetworkComputers
    }

    private func updateSavedComputers() {
        savedComputers = savedConnections.items
            .map(Connection.fromSavedConnection)
            .sorted { $0.name < $1.name }
    }

    private func handleScanningStateChange(_ isScanning: Bool) {
        cleanupTimers()

        if isScanning && !self.isSearching {
            // Scan starting
            currentScanResults.removeAll()
            scanStartTime = Date()
            self.isSearching = true

            // Show progress indicator immediately for reliable display
            showProgressIndicator = true

            startScanUpdateTimer()
            viewLog("NetworkScan: Starting scan", view: "ConnectionsViewModel")
        } else if !isScanning && self.isSearching {
            // Hide progress indicator immediately
            showProgressIndicator = false

            // Scan ending - add slight delay to prevent rapid on/off
            scanCompletionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.isSearching = false
                    viewLog("NetworkScan: Scan completed", view: "ConnectionsViewModel")
                }
            }
        }
    }

    private func startScanUpdateTimer() {
        // Check for both additions and removals every 0.5 seconds during scanning
        scanUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateNetworkComputersDuringScanning()
            }
        }
    }

    private func updateNetworkComputersDuringScanning() {
        guard isSearching else { return }

        // Check for additions first - add immediately
        let connectionsToAdd = currentScanResults.filter { scanResult in
            !networkComputers.contains(where: { $0.host == scanResult.host })
        }

        if !connectionsToAdd.isEmpty {
            withAnimation(.easeIn(duration: 0.3)) {
                networkComputers.append(contentsOf: connectionsToAdd)
            }

            for connectionToAdd in connectionsToAdd {
                viewLog("NetworkScan: Added connection: \(connectionToAdd.name)", view: "ConnectionsViewModel")
            }
        }

        // Check for removals - only after 1.5+ seconds
        guard let scanStart = scanStartTime,
              Date().timeIntervalSince(scanStart) >= 1.5 else {
            return
        }

        let connectionsToRemove = networkComputers.filter { stableConnection in
            !currentScanResults.contains(where: { $0.host == stableConnection.host })
        }

        if !connectionsToRemove.isEmpty {
            withAnimation(.easeOut(duration: 0.3)) {
                networkComputers.removeAll { connection in
                    connectionsToRemove.contains(where: { $0.host == connection.host })
                }
            }

            for connectionToRemove in connectionsToRemove {
                viewLog("NetworkScan: Removed connection: \(connectionToRemove.name)", view: "ConnectionsViewModel")
            }
        }
    }

    private func cleanupTimers() {
        scanCompletionTimer?.invalidate()
        scanCompletionTimer = nil
        scanUpdateTimer?.invalidate()
        scanUpdateTimer = nil
    }


    func checkForRescanOnForeground() {
        viewLog("checkForRescanOnForeground - always scanning when app comes to foreground", view: "ConnectionsViewModel")

        if !isSearching {
            viewLog("Starting rescan on app foreground", view: "ConnectionsViewModel")
            startNetworkScan()
        } else {
            viewLog("Skipping rescan - already scanning", view: "ConnectionsViewModel")
        }
    }
}
