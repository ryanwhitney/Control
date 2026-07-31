import SwiftUI
import Foundation
import Combine

/// The data the host-key review screen needs to render: the Mac's name and
/// host (the host's shape picks which conclusions apply), the new (rejected)
/// fingerprint, the fingerprint(s) previously trusted, and any similarly
/// named Macs visible on the network right now — observed facts the
/// conclusion pages can state instead of hypothesizing. Shared between
/// `ConnectionsViewModel` (which computes it once, in
/// `makeHostKeyReviewContext`) and `HostKeyReviewView` (which renders it), so
/// the two don't carry two independently-maintained field lists.
struct HostKeyReviewRequest {
    let displayName: String
    let host: String
    let newKey: SSHHostKeyInfo
    let previousKeys: [SavedConnections.TrustedHostKey]
    let similarNamedNearby: [String]
}

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
    /// buttons, message and dismissal handling. One enum rather than parallel
    /// optional fields, so every state the alert can be in is a single value
    /// rather than a combination to keep in sync.
    @Published private(set) var pendingRecovery: PendingRecovery = .none
    /// Presents the host-key review screen (reached from the alert's "Review…").
    @Published var showingHostKeyReview = false
    /// The data the host-key review screen needs, set once when a mismatch is
    /// recorded (`enterHostKeyMismatchRecovery`) rather than recomputed on
    /// every access — the alert and the sheet each read it independently.
    @Published private(set) var hostKeyReviewContext: HostKeyReviewRequest?

    struct AddressRepair: Equatable {
        let id = UUID()
        let computer: Connection
        let replacement: Connection
        /// The key that triggered this repair search, carried so a failed
        /// accept (the row moved or vanished mid-probe) can fall back to the
        /// plain mismatch alert instead of losing the failure entirely.
        let rejectedKey: SSHHostKeyInfo
        /// The trusted fingerprint the probe actually saw at `replacement`.
        /// The reconnect expects this one key rather than the host's whole
        /// trusted set, so it can't land on a different machine holding some
        /// other pinned key.
        let verifiedFingerprint: String

        /// Alert copy varies by what actually changed: pure address move vs.
        /// a Bonjour rename ("Mac mini (2)").
        var message: String {
            if replacement.name.caseInsensitiveCompare(computer.name) == .orderedSame {
                return "\(computer.name) is answering from a new address on your network. Its fingerprint matches one Control already trusts, so this really is your Mac."
            } else {
                return "\(computer.name) is now named “\(replacement.name)” on your network. Its fingerprint matches one Control already trusts, so this really is your Mac."
            }
        }
    }

    /// The list presents every connection problem through one alert. Title
    /// and message come from whichever case `pendingRecovery` is in.
    var alertTitle: String {
        if case .addressRepair(let repair) = pendingRecovery { return "\(repair.computer.name) Has a New Address" }
        return connectionError?.title ?? ""
    }

    var alertMessage: String {
        if case .addressRepair(let repair) = pendingRecovery { return repair.message }
        return connectionError?.message ?? ""
    }

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

    /// Long enough for a pop or an alert dismissal to finish before the next
    /// alert is raised. SwiftUI drops one presented into a running transition.
    private static let alertPresentationDelay: UInt64 = 400_000_000

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

    /// The recovery the current connection-error alert offers.
    enum PendingRecovery: Equatable {
        case none
        case authFailure
        case hostKeyMismatch(rejectedKey: SSHHostKeyInfo)
        /// A key-verified address repair offer: `computer`'s pinned identity
        /// answered a credential-free probe at `replacement`'s address, so the
        /// mismatch at the old address is a stale name or address and
        /// rebinding is cryptographically safe.
        case addressRepair(AddressRepair)
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

        if let savedConnection = savedConnections.connection(for: computer.host) {
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

    func connectWithCredentials(computer: Connection, expecting: Set<String>? = nil) {
        viewLog("ConnectionsViewModel: Attempting connection with saved credentials", view: "ConnectionsViewModel")

        logConnectionAttempt(computer: computer)
        connectingComputer = computer

        Task {
            do {
                let hostKey = try await performConnection(computer: computer, expecting: expecting)
                connectingComputer = nil
                savedConnections.pinHostKey(hostKey, for: computer.host)
                navigateToApp(computer: computer)
            } catch {
                connectingComputer = nil
                await handleConnectionError(error: error, computer: computer)
            }
        }
    }

    /// "Add", where credentials are optional. With both filled in this is a
    /// normal connect. With either blank there is nothing to authenticate
    /// with, so a credential-free probe confirms the Mac is really there,
    /// saves it, and asks for the login. An address that answers nothing
    /// errors and saves no row, so a typo leaves nothing behind.
    func addConnection(computer: Connection) {
        guard username.isEmpty || password.isEmpty else {
            connectWithNewCredentials(computer: computer)
            return
        }

        logConnectionAttempt(computer: computer)
        connectingComputer = computer

        Task {
            let found = await SSHTransportConnector.probeHostKey(host: computer.host) != nil
            connectingComputer = nil

            guard found else {
                await handleConnectionError(
                    error: SSHError.connectionFailed("no SSH host answered at \(computer.host)"),
                    computer: computer
                )
                return
            }

            // The probe proves an SSH host is there, not which one, so nothing
            // is pinned yet — the first authenticated connect establishes trust.
            // No credentials were entered, so none are written: re-adding a Mac
            // that's already saved must not disturb its stored login.
            savedConnections.add(
                hostname: computer.host,
                name: computer.name,
                username: username.isEmpty ? nil : username,
                saveCredentials: nil
            )
            selectedConnection = computer
            isAuthenticating = true
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
                    expecting: approvedHostKey.map { [$0.fingerprint] }
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
                await handleConnectionError(error: error, computer: computer)
            }
        }
    }

    /// The user tapped "Verify" on the host-key-change alert — open the review
    /// screen. State stays put; the screen's buttons drive the outcome.
    func openHostKeyReview() {
        showingHostKeyReview = true
    }

    /// The user chose to trust the new key ("Trust & Reconnect" in the verify
    /// flow). The rejected key is trusted for the
    /// retry only; the normal pin-on-success path persists it once the reconnect
    /// verifies it, so a retry that never succeeds leaves no trust behind. Acts
    /// on `recoveryComputer` (the Mac that failed), which — unlike
    /// `selectedConnection` — is set in every flow, including add-connection.
    func confirmHostKeyChangeAndReconnect() {
        guard let computer = recoveryComputer else { return }
        let approvedKey: SSHHostKeyInfo?
        if case .hostKeyMismatch(let rejected) = pendingRecovery {
            approvedKey = rejected
        } else {
            approvedKey = nil
        }
        showingHostKeyReview = false
        clearRecoveryState()
        // Trusting a key is not a credential change. Persist under the Mac's
        // own stored preference rather than whatever this view model last held,
        // which for an in-session mismatch was set by some other flow entirely
        // and could clear a password the user never asked to remove.
        saveCredentials = savedConnections.getSaveCredentialsPreference(for: computer.host)
        connectWithNewCredentials(computer: computer, approvedHostKey: approvedKey)
    }

    /// The user declined ("Cancel" on the alert, "Don't Connect" on the review
    /// screen). Nothing is trusted or persisted.
    func cancelHostKeyMismatch() {
        showingHostKeyReview = false
        clearRecoveryState()
        resetSelection()
    }

    /// Records the failure and the review screen's data, then resolves the
    /// address-repair search before returning, so callers present an outcome
    /// rather than a pending state. Shared by both mismatch entry points so
    /// they can't drift in what they offer for the same failure.
    private func enterHostKeyMismatchRecovery(rejectedKey: SSHHostKeyInfo, computer: Connection) async {
        recoveryComputer = computer
        pendingRecovery = .hostKeyMismatch(rejectedKey: rejectedKey)
        hostKeyReviewContext = makeHostKeyReviewContext(rejectedKey: rejectedKey, computer: computer)
        let formatted = SSHError.hostKeyMismatch(observed: rejectedKey).formatError(displayName: computer.name)
        connectionError = (formatted.title, formatted.message)
        await attemptAddressRepair(for: computer, rejectedKey: rejectedKey)
    }

    /// The Mac's name and host (the host's shape picks which conclusions
    /// apply), the new (rejected) fingerprint, the fingerprint(s) previously
    /// trusted, and any similarly named Macs visible on the network right
    /// now — observed facts the conclusion pages can state instead of
    /// hypothesizing.
    private func makeHostKeyReviewContext(rejectedKey: SSHHostKeyInfo, computer: Connection) -> HostKeyReviewRequest {
        let stem = HostIdentityHeuristics.nameStem(computer.name)
        let nearby = networkComputers
            .filter {
                $0.host.caseInsensitiveCompare(computer.host) != .orderedSame
                    && !stem.isEmpty
                    && HostIdentityHeuristics.nameStem($0.name) == stem
            }
            .map(\.name)
        return HostKeyReviewRequest(
            displayName: computer.name,
            host: computer.host,
            newKey: rejectedKey,
            previousKeys: savedConnections.trustedHostKeys(for: computer.host),
            similarNamedNearby: nearby
        )
    }

    /// A mismatch hit from ControlView or the setup flow, neither of which can
    /// reach the store. Resolves recovery here, then pops back to the list to
    /// present it. The Mac is resolved from the host being reconnected to
    /// rather than `selectedConnection`, which any pop clears; returns false if
    /// it can't be identified, so the caller surfaces the failure itself
    /// instead of leaving the view connecting against an alert that never comes.
    private func handleInSessionHostKeyMismatch(host: String, rejectedKey: SSHHostKeyInfo) async -> Bool {
        func matchesHost(_ connection: Connection) -> Bool {
            connection.host.caseInsensitiveCompare(host) == .orderedSame
        }
        guard let computer = savedComputers.first(where: matchesHost)
                ?? selectedConnection.flatMap({ matchesHost($0) ? $0 : nil }) else { return false }
        await enterHostKeyMismatchRecovery(rejectedKey: rejectedKey, computer: computer)
        presentMismatchOnReturn = true
        navigateToControl = false
        showingSetupFlow = false
        return true
    }

    /// Called by the list once it's back on screen after an in-session mismatch
    /// popped a detail view. Deferred so the alert presents after the pop
    /// animation settles rather than racing it.
    func presentPendingMismatchAlertIfNeeded() {
        guard presentMismatchOnReturn else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.alertPresentationDelay)
            // A tap on another Mac inside the delay would raise this Mac's
            // alert over that connect, and "Review…" would open the wrong
            // fingerprint. The flag stays set so the next return to the list
            // presents it; `clearRecoveryState` is what retires it. The
            // setup-flow pop leaves `selectedConnection` on the failed Mac, so
            // only a switch to a different one disqualifies.
            guard presentMismatchOnReturn,
                  connectingComputer == nil,
                  !isAuthenticating,
                  selectedConnection == nil || selectedConnection?.id == recoveryComputer?.id else { return }
            presentMismatchOnReturn = false
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
            resetSelection()
        }
    }

    /// Backs out of the current selection entirely: no computer, no entered
    /// credentials. Shared by every dismissal that isn't re-prompting for
    /// the same computer.
    private func resetSelection() {
        selectedConnection = nil
        username = ""
        password = ""
    }

    /// `hostKeyReviewContext` deliberately survives: the review sheet reads it
    /// while it animates away, and the next mismatch overwrites it. Nothing can
    /// reach a stale one, since every route in is gated on `pendingRecovery`.
    private func clearRecoveryState() {
        pendingRecovery = .none
        recoveryComputer = nil
        connectingComputer = nil
        presentMismatchOnReturn = false
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

    /// Points the shared connection manager at this view model, which owns both
    /// the store and the recovery UI an in-session mismatch needs. Installed
    /// when the list appears rather than at init because SwiftUI may build and
    /// discard a `@StateObject`'s initial value, and a discarded view model
    /// must not leave its handlers behind on the manager.
    private func installConnectionHandlers() {
        connectionManager.trustedHostKeyProvider = { [weak self] host in
            self?.savedConnections.trustedHostKeyFingerprints(for: host)
        }
        connectionManager.hostKeyMismatchHandler = { [weak self] host, rejectedKey in
            await self?.handleInSessionHostKeyMismatch(host: host, rejectedKey: rejectedKey) ?? false
        }
    }

    func onAppear() {
        installConnectionHandlers()
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
    /// `expecting` narrows the connect to one specific key the user or a probe
    /// just verified, instead of the host's whole trusted set — so a reconnect
    /// meant for that key can't be satisfied by a different machine whose key
    /// also happens to be pinned.
    private func performConnection(computer: Connection, expecting: Set<String>? = nil) async throws -> SSHHostKeyInfo {
        // `connect()` tears down any existing connection itself, so there's no
        // pre-disconnect step here.
        let trusted = expecting ?? savedConnections.trustedHostKeyFingerprints(for: computer.host)
        let hostKey = try await connectionManager.connect(
            host: computer.host,
            username: username,
            password: password,
            trustedHostKeyFingerprints: trusted
        )

        viewLog("✓ ConnectionsViewModel: Connection verified successfully", view: "ConnectionsViewModel")
        return hostKey
    }

    private func handleConnectionError(error: Error, computer: Connection) async {
        isAuthenticating = false

        if case SSHError.hostKeyMismatch(let observed) = error {
            await enterHostKeyMismatchRecovery(rejectedKey: observed, computer: computer)
            showingError = true
            return
        }

        if let sshError = error as? SSHError {
            viewLog("✅ Successfully handled SSHError: \(sshError)", view: "ConnectionsViewModel")
            let formattedError = sshError.formatError(displayName: computer.name)
            connectionError = (formattedError.title, formattedError.message)

            // Re-prompt for credentials on an auth failure; a plain dismissal
            // for anything else (mismatch is handled above and returns early).
            if case .authenticationFailed = sshError {
                pendingRecovery = .authFailure
            } else {
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

    /// After a mismatch, searches the network for the Mac's pinned identity at
    /// another address: a Bonjour host with the same name stem may be the same
    /// Mac renamed or re-addressed. Probes are key-exchange only, so no
    /// credentials are ever offered to anything. Exactly one verified match
    /// moves `pendingRecovery` to the repair offer; zero or several (several
    /// means cloned keys, where only the user knows which box they mean)
    /// leave `pendingRecovery` at the plain mismatch this was called with.
    private func attemptAddressRepair(for computer: Connection, rejectedKey: SSHHostKeyInfo) async {
        let pinned = savedConnections.trustedHostKeyFingerprints(for: computer.host)
        // Bounded generously: probing runs concurrently against a shared
        // event-loop group, so a batch is cheap, but an unusually large LAN
        // result shouldn't spawn an unbounded number of simultaneous probes.
        let candidates = Array(addressRepairCandidates(for: computer).prefix(6))
        guard !pinned.isEmpty, !candidates.isEmpty else { return }

        // Keep the row's spinner up while probing so the pause reads as work,
        // and so a second tap can't start a competing connect.
        connectingComputer = computer
        let observed = await SSHTransportConnector.probeHostKeys(hosts: candidates.map(\.host), timeout: 3.0)
        connectingComputer = nil

        let matches = candidates.compactMap { candidate -> (Connection, String)? in
            guard let fingerprint = observed[candidate.host]?.fingerprint,
                  pinned.contains(fingerprint) else { return nil }
            return (candidate, fingerprint)
        }
        guard matches.count == 1, let (match, verified) = matches.first else { return }

        viewLog("Address repair: pinned key for \(computer.host.redacted()) verified at \(match.host.redacted())", view: "ConnectionsViewModel")
        pendingRecovery = .addressRepair(AddressRepair(
            computer: computer,
            replacement: match,
            rejectedKey: rejectedKey,
            verifiedFingerprint: verified
        ))
    }

    /// Discovered hosts that could be `computer` under a new name or address:
    /// same name stem, different host, and not already saved as their own
    /// connection (repairing onto an existing row would merge two Macs).
    private func addressRepairCandidates(for computer: Connection) -> [Connection] {
        let stem = HostIdentityHeuristics.nameStem(computer.name)
        guard !stem.isEmpty else { return [] }
        return networkComputers.filter { candidate in
            candidate.host.caseInsensitiveCompare(computer.host) != .orderedSame
                && HostIdentityHeuristics.nameStem(candidate.name) == stem
                && !savedComputers.contains { $0.host.caseInsensitiveCompare(candidate.host) == .orderedSame }
        }
    }

    /// "Update & Connect" on the repair offer: move the saved row (pins,
    /// password, preferences) to the verified address and reconnect. Trust
    /// carries over because the key at the new address already matched it.
    func acceptAddressRepair(_ repair: AddressRepair) {
        guard savedConnections.updateHostname(from: repair.computer.host, to: repair.replacement.host) else {
            // The row moved or vanished while the probe ran. Connecting now
            // would repair nothing and pin nothing, so fall back to the plain
            // mismatch alert rather than quietly trusting-on-first-use.
            pendingRecovery = .hostKeyMismatch(rejectedKey: repair.rejectedKey)
            presentAlertAfterDismissal()
            return
        }
        // The offer named the Mac's current Bonjour name; carry it over so the
        // list doesn't keep showing the one the alert just superseded.
        savedConnections.updateName(repair.replacement.name, for: repair.replacement.host)
        clearRecoveryState()
        connectWithCredentials(computer: repair.replacement, expecting: [repair.verifiedFingerprint])
    }

    /// "Not Now" on the repair offer: nothing moves and nothing is trusted, but
    /// the old address did fail verification, so fall through to the mismatch
    /// alert rather than returning to a list that looks untroubled. That alert
    /// carries the explanation and the route to the fingerprint review.
    func declineAddressRepair() {
        guard case .addressRepair(let repair) = pendingRecovery else { return }
        pendingRecovery = .hostKeyMismatch(rejectedKey: repair.rejectedKey)
        presentAlertAfterDismissal()
    }

    /// Re-presents the alert after one has just been dismissed. An alert raised
    /// while the previous one's dismissal is still animating doesn't present.
    private func presentAlertAfterDismissal() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.alertPresentationDelay)
            showingError = true
        }
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
        let connectionType = HostProvenance(host: computer.host) == .localHostname ? "Bonjour (.local)" : "Manual IP"
        viewLog("Connection type: \(connectionType)", view: "ConnectionsViewModel")
        viewLog("Computer name: \(computer.name.redacted())", view: "ConnectionsViewModel")
        viewLog("Host: \(computer.host.redacted())", view: "ConnectionsViewModel")
    }

    private func updateNetworkComputersStably() {
        currentScanResults = networkScanner.services.compactMap { service in
            // The store normalizes the hostname it's asked about itself.
            Connection.fromNetService(service, lastUsername: savedConnections.lastUsername(for: service.hostName ?? ""))
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
