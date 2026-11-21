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
    /// The edit sheet's "Open on launch" toggle.
    @Published var opensOnLaunch = false
    @Published var isAuthenticating = false
    @Published var connectionError: (title: String, message: String)?
    @Published var showingAddDialog = false
    @Published var showingError = false
    @Published var showingSetupFlow = false
    @Published var navigateToControl = false
    @Published var activePopover: ActivePopover?
    @Published var showingWhatsNew = false
    @Published var lastErrorWasAuthFailure = false

    @Published var networkComputers: [Connection] = []
    @Published var savedComputers: [Connection] = []
    @Published var isSearching = false
    @Published var showProgressIndicator = false
    @Published var showStatusRow = false

    private var currentScanResults: [Connection] = []
    private var scanStartTime: Date?
    private var scanCompletionTimer: Timer?
    private var scanUpdateTimer: Timer?
    /// Launch routing waits for the root view, which disconnects on appear.
    private var hasAppeared = false
    /// A Mac to open once the screen in the way has been popped.
    private var pendingOpenHost: String?

    let savedConnections = SavedConnections()
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

        updateSavedComputers(savedConnections.items)
        viewLog("Init: saved computers count: \(savedComputers.count)", view: "ConnectionsViewModel")

        isSearching = networkScanner.isScanning
        viewLog("Init: scanner.isScanning: \(networkScanner.isScanning), services count: \(networkScanner.services.count)", view: "ConnectionsViewModel")

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

        // Map the published value directly and synchronously. @Published fires
        // on willSet, so re-reading savedConnections.items here would see the
        // old array — and deferring via receive(on:) updated the List a tick
        // after a destructive swipe action's eager row removal, crashing
        // UICollectionView with "invalid number of items in section".
        savedConnections.$items
            .sink { [weak self] items in
                self?.updateSavedComputers(items)
            }
            .store(in: &cancellables)

        HomeScreenQuickActions.shared.$requestedHost
            .compactMap { $0 }
            .sink { [weak self] host in
                guard let self, hasAppeared else { return }
                HomeScreenQuickActions.shared.requestedHost = nil
                open(host: host)
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
        opensOnLaunch = savedConnections.launchHost == computer.host
        showingAddDialog = true
    }

    func updateCredentials(hostname: String, name: String?, username: String, password: String?, saveCredentials: Bool, opensOnLaunch: Bool) {
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
        savedConnections.setOpensOnLaunch(saveCredentials && opensOnLaunch, for: hostname)
    }

    // MARK: Opening a Mac directly

    /// Opens a saved Mac from outside the list: at launch, or from a Home
    /// Screen quick action. With a saved login it goes straight to the
    /// controls, connecting there; otherwise it takes the list's own path,
    /// prompting for a login or running first-time setup.
    func open(host: String) {
        guard let saved = savedConnections.items.first(where: { $0.hostname == host }) else { return }
        let computer = Connection.fromSavedConnection(saved)
        if (navigateToControl || showingSetupFlow) && selectedConnection?.host == host { return }
        // A connect already under way from the list lands on its own Mac.
        guard connectingComputer == nil else { return }

        activePopover = nil
        showingAddDialog = false
        isAuthenticating = false

        if navigateToControl || showingSetupFlow {
            // The pop's own cleanup disconnects and clears the selection;
            // `resumePendingOpen` picks this up after it.
            pendingOpenHost = host
            withoutAnimation {
                navigateToControl = false
                showingSetupFlow = false
            }
            return
        }

        guard savedConnections.canOpenDirectly(host) else {
            selectComputer(computer)
            return
        }
        selectedConnection = computer
        username = saved.username ?? ""
        password = savedConnections.password(for: host) ?? ""
        saveCredentials = true
        withoutAnimation { navigateToControl = true }
    }

    /// Called by the root view once a screen popped for `open` is gone.
    func resumePendingOpen() {
        guard let host = pendingOpenHost else { return }
        pendingOpenHost = nil
        // Pushing in the same update as the pop gets dropped.
        Task { @MainActor in
            open(host: host)
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        Task { @MainActor in
            connectionManager.handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
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
        
        if !showStatusRow {
            Task {
                // delay showing immediately to prevent the default value from flashing
                try await Task.sleep(nanoseconds: 50_000_000)
                showStatusRow = true
            }
        }
        
        if !hasAppeared {
            hasAppeared = true
            let quickActionHost = HomeScreenQuickActions.shared.requestedHost
            HomeScreenQuickActions.shared.requestedHost = nil
            if let host = quickActionHost ?? savedConnections.launchHost {
                open(host: host)
            }
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
        // `connect()` tears down any existing connection itself, so there's no
        // pre-disconnect step here.
        try await connectionManager.connect(
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

            // Track if this was an auth failure so we can re-prompt for credentials
            if case .authenticationFailed = sshError {
                lastErrorWasAuthFailure = true
            } else {
                lastErrorWasAuthFailure = false
            }
        } else {
            viewLog("❌ Handling generic error", view: "ConnectionsViewModel")
            connectionError = (
                "Connection Error",
                """
                An unexpected error occurred while connecting to \(computer.name).

                Technical details: \(error.localizedDescription)
                """
            )
            lastErrorWasAuthFailure = false
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
        viewLog("Computer name: \(computer.name.redacted())", view: "ConnectionsViewModel")
        viewLog("Host: \(computer.host.redacted())", view: "ConnectionsViewModel")
    }

    private func updateNetworkComputersStably() {
        currentScanResults = networkScanner.services.compactMap { service in
            Connection.fromNetService(service, lastUsername: savedConnections.lastUsername(for: service.hostName?.replacingOccurrences(of: ".local.", with: ".local") ?? ""))
        }

        // Build the new list locally and assign once, so the UI sees a single
        // update instead of flickering through each insertion.
        var updatedNetworkComputers = networkComputers

        for scanResult in currentScanResults {
            if !updatedNetworkComputers.contains(where: { $0.host == scanResult.host }) {
                viewLog("NetworkScan: Adding new connection: \(scanResult.name)", view: "ConnectionsViewModel")
                updatedNetworkComputers.append(scanResult)
            }
        }

        // Pick up lastUsername changes for connections we already show.
        for i in 0..<updatedNetworkComputers.count {
            if let updatedConnection = currentScanResults.first(where: { $0.host == updatedNetworkComputers[i].host }) {
                if updatedNetworkComputers[i].lastUsername != updatedConnection.lastUsername {
                    updatedNetworkComputers[i] = updatedConnection
                }
            }
        }

        networkComputers = updatedNetworkComputers
    }

    private func updateSavedComputers(_ items: [SavedConnections.SavedConnection]) {
        savedComputers = items
            .map(Connection.fromSavedConnection)
            .sorted { $0.name < $1.name }
        HomeScreenQuickActions.shared.update(for: savedComputers)
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
            networkComputers.append(contentsOf: connectionsToAdd)

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
            networkComputers.removeAll { connection in
                connectionsToRemove.contains(where: { $0.host == connection.host })
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
