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
    /// Which recovery the current error alert should offer. Drives the alert's
    /// buttons (mismatch → Verify / Trust & Reconnect / Cancel) and the
    /// dismissal handling.
    @Published private(set) var pendingRecovery: PendingRecovery = .none
    /// Presents the host-key review screen (reached from the alert's "Verify").
    @Published var showingHostKeyReview = false

    @Published var networkComputers: [Connection] = []
    @Published var savedComputers: [Connection] = []
    @Published var isSearching = false
    @Published var showProgressIndicator = false
    @Published var showStatusRow = false

    private var currentScanResults: [Connection] = []
    private var scanStartTime: Date?
    private var scanCompletionTimer: Timer?
    private var scanUpdateTimer: Timer?

    /// The computer whose connect most recently failed, so recovery (retry after
    /// a confirmed host-key change, or re-prompt) acts on the Mac that actually
    /// failed rather than `selectedConnection`, which isn't set in the
    /// add-connection flow.
    private var recoveryComputer: Connection?

    /// Set when an in-session mismatch has popped the user back to the list;
    /// the list presents the verify/reconnect alert once it's on screen again.
    private var presentMismatchOnReturn = false

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

    /// The recovery the current connection-error alert offers, replacing the
    /// old parallel bool flags so invalid combinations can't arise and stale
    /// state can't leak into a later alert.
    enum PendingRecovery: Equatable {
        case none
        case authFailure
        case hostKeyMismatch(rejectedKey: SSHHostKeyInfo?)
    }

    var hasConnections: Bool {
        !networkComputers.isEmpty || !savedComputers.isEmpty
    }

    init() {
        viewLog("ConnectionsViewModel init starting", view: "ConnectionsViewModel")

        // Let in-session reconnects (handleConnection) resolve trusted keys from
        // the store, keyed by host, without the manager holding a reference to it.
        connectionManager.trustedHostKeyProvider = { [savedConnections] host in
            savedConnections.trustedHostKeyFingerprints(for: host)
        }
        // Route in-session mismatches back into this list's verify/reconnect flow.
        connectionManager.hostKeyMismatchHandler = { [weak self] rejectedKey in
            self?.handleInSessionHostKeyMismatch(rejectedKey: rejectedKey)
        }

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
                let hostKey = try await performConnection(computer: computer)
                connectingComputer = nil
                savedConnections.pinHostKey(hostKey, for: computer.host)
                navigateToApp(computer: computer)
            } catch {
                connectingComputer = nil
                handleConnectionError(error: error, computer: computer)
            }
        }
    }

    /// `approvedHostKey` is set only when reconnecting after the user confirmed
    /// a host-key change: it is trusted for this one attempt so the connect can
    /// proceed, and persisted (below) only once the connection actually
    /// succeeds — never before it's verified.
    func connectWithNewCredentials(computer: Connection, approvedHostKey: SSHHostKeyInfo? = nil) {
        viewLog("ConnectionsViewModel: Attempting connection with new credentials", view: "ConnectionsViewModel")

        logConnectionAttempt(computer: computer)
        connectingComputer = computer

        Task {
            do {
                let hostKey = try await performConnection(
                    computer: computer,
                    additionalTrustedFingerprints: approvedHostKey.map { [$0.fingerprint] } ?? []
                )
                connectingComputer = nil

                viewLog("Saving credentials after successful verification with saveCredentials: \(saveCredentials)", view: "ConnectionsViewModel")
                savedConnections.add(
                    hostname: computer.host,
                    name: computer.name,
                    username: username,
                    password: saveCredentials ? password : nil,
                    saveCredentials: saveCredentials
                )
                // Pin after `add(...)`: for a brand-new host that call creates
                // the row `pinHostKey` writes into.
                savedConnections.pinHostKey(hostKey, for: computer.host)

                navigateToApp(computer: computer)
            } catch {
                connectingComputer = nil
                handleConnectionError(error: error, computer: computer)
            }
        }
    }

    /// The data the host-key review screen needs: the Mac's name, the new
    /// (rejected) fingerprint being presented, and the fingerprint(s) previously
    /// trusted — so the screen can tell the user which one a manual check should
    /// match. Nil unless a mismatch is awaiting review.
    var hostKeyReviewContext: (displayName: String, newKey: SSHHostKeyInfo, previousKeys: [SavedConnections.TrustedHostKey])? {
        guard let computer = recoveryComputer,
              case .hostKeyMismatch(let rejected) = pendingRecovery,
              let key = rejected else { return nil }
        return (computer.name, key, savedConnections.trustedHostKeys(for: computer.host))
    }

    /// The user tapped "Verify" on the host-key-change alert — open the review
    /// screen. State stays put; the screen's buttons drive the outcome.
    func openHostKeyReview() {
        showingHostKeyReview = true
    }

    /// The user chose to trust the new key ("Trust & Reconnect" on the alert or
    /// the review screen). The rejected key is trusted for the
    /// retry only; the normal pin-on-success path persists it once the reconnect
    /// verifies it, so a retry that never succeeds leaves no trust behind. Acts
    /// on `recoveryComputer` (the Mac that failed), which — unlike
    /// `selectedConnection` — is set in every flow, including add-connection.
    func confirmHostKeyChangeAndReconnect() {
        guard let computer = recoveryComputer else { return }
        var approvedKey: SSHHostKeyInfo?
        if case .hostKeyMismatch(let rejected) = pendingRecovery { approvedKey = rejected }
        showingHostKeyReview = false
        clearRecoveryState()
        connectWithNewCredentials(computer: computer, approvedHostKey: approvedKey)
    }

    /// The user declined ("Cancel" on the alert, "Don't Connect" on the review
    /// screen). Nothing is trusted or persisted.
    func cancelHostKeyMismatch() {
        showingHostKeyReview = false
        clearRecoveryState()
        selectedConnection = nil
        username = ""
        password = ""
    }

    /// An in-session reconnect (ControlView / setup flow) hit a mismatch. Rather
    /// than trust or reconnect from a screen that can't reach the store, capture
    /// the failure, pop back to the connections list, and present the same
    /// verify/reconnect alert there — one recovery path for both entry points.
    private func handleInSessionHostKeyMismatch(rejectedKey: SSHHostKeyInfo?) {
        guard let computer = selectedConnection else { return }
        recoveryComputer = computer
        pendingRecovery = .hostKeyMismatch(rejectedKey: rejectedKey)
        let formatted = SSHError.hostKeyMismatch(observed: rejectedKey).formatError(displayName: computer.name)
        connectionError = (formatted.title, formatted.message)
        presentMismatchOnReturn = true
        navigateToControl = false
        showingSetupFlow = false
    }

    /// Called by the list once it's back on screen after an in-session mismatch
    /// popped a detail view. Deferred so the alert presents after the pop
    /// animation settles rather than racing it.
    func presentPendingMismatchAlertIfNeeded() {
        guard presentMismatchOnReturn else { return }
        presentMismatchOnReturn = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            showingError = true
        }
    }

    /// "OK" on a non-mismatch error alert: re-prompt for credentials after an
    /// auth failure, otherwise clear state and return to the list.
    func dismissConnectionError() {
        let wasAuthFailure = pendingRecovery == .authFailure
        clearRecoveryState()
        if wasAuthFailure {
            password = ""
            isAuthenticating = true
        } else {
            selectedConnection = nil
            username = ""
            password = ""
        }
    }

    private func clearRecoveryState() {
        pendingRecovery = .none
        recoveryComputer = nil
        connectingComputer = nil
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

    /// Connects and returns the host key the server presented (for pinning).
    /// `additionalTrustedFingerprints` is empty for a normal connect; on a
    /// user-approved reconnect after a host-key change it carries the newly
    /// approved key so this one attempt accepts it.
    private func performConnection(computer: Connection, additionalTrustedFingerprints: Set<String> = []) async throws -> SSHHostKeyInfo {
        // `connect()` tears down any existing connection itself, so there's no
        // pre-disconnect step here.
        var trusted = savedConnections.trustedHostKeyFingerprints(for: computer.host)
        trusted.formUnion(additionalTrustedFingerprints)
        let hostKey = try await connectionManager.connect(
            host: computer.host,
            username: username,
            password: password,
            trustedHostKeyFingerprints: trusted
        )

        viewLog("✓ ConnectionsViewModel: Connection verified successfully", view: "ConnectionsViewModel")
        return hostKey
    }

    private func handleConnectionError(error: Error, computer: Connection) {
        isAuthenticating = false

        if let sshError = error as? SSHError {
            viewLog("✅ Successfully handled SSHError: \(sshError)", view: "ConnectionsViewModel")
            let formattedError = sshError.formatError(displayName: computer.name)
            connectionError = (formattedError.title, formattedError.message)

            // Pick the recovery the alert should offer: re-prompt for
            // credentials (auth failure), the verify/trust/cancel choice
            // (host-key mismatch), or a plain dismissal for anything else.
            switch sshError {
            case .authenticationFailed:
                pendingRecovery = .authFailure
            case .hostKeyMismatch(let observed):
                pendingRecovery = .hostKeyMismatch(rejectedKey: observed)
            default:
                pendingRecovery = .none
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
            pendingRecovery = .none
        }
        recoveryComputer = computer
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
