import Foundation
import SwiftUI
import Network

@MainActor
class SSHConnectionManager: ObservableObject, SSHClientProtocol {
    /// Set only by the manager and its extensions (+Heartbeat drives the
    /// recovering/connected transitions, hence no `private(set)`).
    @Published var connectionState: ConnectionState = .disconnected
    /// Active SSH transport, selected per `UserPreferences.connectionMethod` on
    /// each connect. `nonisolated(unsafe)`: it is assigned on the MainActor in
    /// `connect()` before any command is dispatched, and only read thereafter.
    private nonisolated(unsafe) var sshClient: SSHClientProtocol
    private var currentCredentials: Credentials?
    private var connectionLostHandler: (@MainActor (Error?) -> Void)?
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "SSHPathMonitor")

    // MARK: - Heartbeat state (used by +Heartbeat, so not private)
    var heartbeatTask: Task<Void, Never>?
    /// Bumped by `stopHeartbeat()`. In-flight pings capture the value they were
    /// sent under, so a stale watchdog/reply from a stopped or replaced
    /// heartbeat can't flip a fresh connection into `.recovering`.
    var heartbeatGeneration: UInt64 = 0
    var consecutiveHeartbeatFailures = 0
    let maxHeartbeatFailures = 2
    /// Fast pings are the streaming transport's wedge canary. On Compatibility
    /// every ping spawns a login shell + osascript on the Mac, and LAN RTTs can
    /// exceed 0.5 s (overlapping replies), so it pings less aggressively.
    var minHeartbeatInterval: TimeInterval {
        activeConnectionMethod == .compatibility ? 2 : 0.5
    }
    let maxHeartbeatInterval: TimeInterval = 12
    var currentHeartbeatInterval: TimeInterval = 3
    var recoveryDeadline: Date?
    var heartbeatCounter: UInt32 = 0
    let heartbeatReplyTimeout: TimeInterval = 2.5

    // MARK: - Lifecycle state (used by +Lifecycle, so not private)
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var backgroundDisconnectTimer: DispatchWorkItem?
    var lastScenePhaseChange: (from: ScenePhase, to: ScenePhase, time: Date)?

    // MARK: - Streaming transport auto-fallback
    /// Canary for the streaming transport: true once *any* real reply — a
    /// command result or a heartbeat echo — has landed on the current
    /// connection, distinguishing "connected but the stream never replied"
    /// from a live connection. Command replies count because a busy Mac (Low
    /// Power Mode, heavy AppleScript) can starve heartbeat echoes while app
    /// commands keep succeeding; that's a slow Mac, not a broken transport.
    /// Reset on every connect; set in `handleHeartbeatSuccess` and
    /// `noteCommandResponded`.
    var connectionEverResponded = false
    /// The transport the *current* connection was built with. Used to decide
    /// whether an unresponsive connection is a streaming-layer failure worth
    /// auto-falling-back (vs. a Compatibility connection, which we leave alone).
    private var activeConnectionMethod: ConnectionMethod?
    /// Transient, non-persisted transport override applied on the next connect.
    /// Set when we auto-fall-back to Compatibility for a Mac whose Fast/streaming
    /// layer is broken; lasts the app session unless the user makes an explicit
    /// choice in Settings. The persisted default stays in `UserPreferences`.
    private var sessionMethodOverride: ConnectionMethod?
    /// One auto-fallback per app session, so a genuinely dead Mac (or a real
    /// network drop) can't ping-pong transports or re-show the notice.
    private var hasAutoFallenBackToCompatibility = false
    /// Invoked on the MainActor when we auto-switch to Compatibility, so the
    /// active view can show the notice and re-drive the connection.
    private var transportFallbackHandler: (@MainActor () -> Void)?

    // MARK: - Reconnect controller
    /// Re-drives a full connect (the view's connect path, so heartbeat + state
    /// refresh run) after an involuntary loss. When nil we surface the loss
    /// immediately instead of auto-reconnecting.
    private var reconnectHandler: (@MainActor () -> Void)?
    /// True from the moment a reconnect is scheduled until it actually starts, so
    /// a burst of loss signals doesn't schedule several overlapping reconnects.
    private var reconnectPending = false
    /// Consecutive auto-reconnect cycles without a stable heartbeat; reset on a
    /// real heartbeat. Caps flapping (connect succeeds then immediately drops)
    /// before we surface the error rather than looping forever.
    var consecutiveReconnects = 0
    private let maxReconnectCycles = 3
    /// Attempts per reconnect drive before the error is surfaced (see handleConnection).
    private let maxConnectAttempts = 3
    /// Benign racy activity timestamp read by the heartbeat loop to speed up pings
    /// after commands — avoids a MainActor Task hop per command.
    /// `nonisolated(unsafe)` matches this class's `sshClient` pattern; Date is a
    /// single 8-byte value so reads/writes don't tear.
    nonisolated(unsafe) var lastActivityAt = Date.distantPast

    static let shared = SSHConnectionManager()
    
    struct Credentials: Equatable {
        let host: String
        let username: String
        let password: String
    }
    
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case recovering
        case failed(String)
        
        var description: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .recovering: return "recovering"
            case .failed(let error): return "failed(\(error))"
            }
        }
    }
    
    init() {
        connectionLog("SSHConnectionManager: Initializing")
        self.sshClient = SSHClient()
        
        // Start monitoring network path changes to detect sudden Wi-Fi drops
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Only a definitively unsatisfied path counts as a drop. Transient
            // states (e.g. .requiresConnection during a Wi-Fi handoff) are left
            // for the heartbeat to confirm, avoiding spurious disconnects.
            if path.status == .unsatisfied {
                connectionLog("🚨 Network path unsatisfied – assuming connection lost")
                Task { @MainActor in
                    self.handleConnectionLost(because: SSHError.connectionFailed("Network path unavailable"))
                }
            } else if path.status == .satisfied {
                // Network came back. If we're mid-recovery, kick the reconnect now
                // rather than waiting out the backoff. Only from `.recovering` to
                // avoid touching a deliberate disconnect (leaving the screen).
                Task { @MainActor in
                    guard self.connectionState == .recovering, !self.reconnectPending,
                          let reconnect = self.reconnectHandler else { return }
                    connectionLog("🛜 Network path restored – reconnecting")
                    self.consecutiveReconnects = 0
                    reconnect()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    func setConnectionLostHandler(_ handler: @escaping @MainActor (Error?) -> Void) {
        self.connectionLostHandler = handler
    }

    func setTransportFallbackHandler(_ handler: @escaping @MainActor () -> Void) {
        self.transportFallbackHandler = handler
    }

    /// Registered by the active view to re-drive its full connect path when the
    /// manager decides to auto-reconnect after an involuntary loss.
    func setReconnectHandler(_ handler: @escaping @MainActor () -> Void) {
        self.reconnectHandler = handler
    }

    /// Called by the registering view when it leaves the screen. The handlers
    /// capture that view's host/credentials, so leaving them registered would
    /// let a loss during a *later* connection (possibly to a different Mac)
    /// silently re-drive the dismissed view's connect path.
    func clearViewHandlers() {
        self.reconnectHandler = nil
        self.transportFallbackHandler = nil
    }

    /// The user made an explicit connection-method choice in Settings; that choice
    /// supersedes any transient auto-fallback and re-arms the one-shot fallback so
    /// a fresh Fast attempt can auto-heal again if it too proves broken.
    func userDidChooseConnectionMethod() {
        sessionMethodOverride = nil
        hasAutoFallenBackToCompatibility = false
    }
    
    nonisolated var client: SSHClientProtocol {
        return sshClient
    }

    /// Forward the active transport's channel model so callers (AppController)
    /// can pick a refresh strategy without knowing which transport is selected.
    nonisolated var serializesAppCommands: Bool {
        sshClient.serializesAppCommands
    }

    /// Builds the SSH transport for the selected connection method.
    private static func makeTransport(for method: ConnectionMethod) -> SSHClientProtocol {
        switch method {
        case .streaming: return SSHClient()
        case .compatibility: return LegacySSHClient()
        }
    }
    
    func handleConnectionLost(because error: Error? = nil, allowTransportFallback: Bool = false) {
        Task { @MainActor in
            // Only a live/recovering connection can be "lost". A loss that arrives
            // mid-(re)connect (state .connecting/.failed) is owned by the connect
            // retry loop, and `reconnectPending` blocks a burst of loss signals
            // from scheduling several overlapping reconnects.
            guard connectionState == .connected || connectionState == .recovering else { return }
            guard !reconnectPending else { return }

            // Streaming-transport canary: we reached `.connected` but not one
            // reply of any kind (command result or heartbeat echo) ever landed →
            // the Fast/streaming layer is broken, not the network or permissions
            // (which would fail Compatibility too). Auto-switch to Compatibility
            // once and let the active view re-drive + show the notice, rather
            // than dead-ending on a "Connection Lost".
            if allowTransportFallback,
               activeConnectionMethod == .streaming,
               !connectionEverResponded,
               !hasAutoFallenBackToCompatibility,
               currentCredentials != nil,
               let fallback = transportFallbackHandler {
                connectionLog("🩹 Fast transport unresponsive on this Mac – auto-switching to Compatibility")
                hasAutoFallenBackToCompatibility = true
                sessionMethodOverride = .compatibility
                self.connectionState = .disconnected
                self.sshClient.disconnect()
                self.stopHeartbeat()
                fallback()
                return
            }

            connectionLog("🚨 Connection lost...")
            self.sshClient.disconnect()
            self.stopHeartbeat()

            // Auto-reconnect a bounded number of cycles before surfacing an error.
            // The flap cap (`consecutiveReconnects`, reset on a real heartbeat)
            // stops a connect-succeeds-then-immediately-drops loop.
            if let reconnect = reconnectHandler, consecutiveReconnects < maxReconnectCycles {
                consecutiveReconnects += 1
                connectionState = .recovering
                reconnectPending = true
                connectionLog("↻ Auto-reconnecting (cycle \(consecutiveReconnects)/\(maxReconnectCycles))")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    reconnectPending = false
                    // Skip if we recovered or were torn down in the meantime.
                    guard connectionState == .recovering else { return }
                    reconnect()   // → connectToSSH → handleConnection retry loop
                }
            } else {
                connectionState = .disconnected
                connectionLostHandler?(error)   // view surfaces it; OK returns to the list
                consecutiveReconnects = 0
            }
        }
    }
    
    func connect(host: String, username: String, password: String) async throws {
        connectionLog("SSHConnectionManager: Connection Request")
        
        // Show connection metadata without exposing sensitive info
        let isLocal = host.contains(".local")
        let connectionType = isLocal ? "Bonjour (.local)" : "TCP/IP"
        let hostRedacted = host.redacted()
        
        connectionLog("Connecting via \(connectionType) to \(hostRedacted)")
        
        // Always clean up first to prevent state corruption
        await cleanupExistingConnection()

        // Select the transport for this connect: a transient auto-fallback
        // override (set when Fast proved broken on some Mac this session) wins
        // over the user's persisted preference.
        let method = sessionMethodOverride ?? UserPreferences.shared.connectionMethod
        sshClient = Self.makeTransport(for: method)
        activeConnectionMethod = method
        connectionEverResponded = false
        connectionLog("Transport: \(method.displayName)\(sessionMethodOverride != nil ? " (auto)" : "")")

        connectionState = .connecting
        reconnectPending = false   // a connect attempt is now the active recovery
        currentCredentials = Credentials(host: host, username: username, password: password)
        
        return try await withCheckedThrowingContinuation { continuation in
            let client = self.client // Capture nonisolated client
            var hasResumed = false
            let connectionId = UUID().uuidString.prefix(8)
            
            client.connect(host: host, username: username, password: password) { result in
                Task { @MainActor in
                    guard !hasResumed else {
                        connectionLog("⚠️ [\(connectionId)] Continuation already resumed, ignoring duplicate result: \(result)")
                        return
                    }
                    hasResumed = true
                    
                    switch result {
                    case .success:
                        connectionLog("✓ [\(connectionId)] Connection successful")
                        self.connectionState = .connected
                        self.consecutiveHeartbeatFailures = 0
                        self.recoveryDeadline = nil
                        continuation.resume()
                    case .failure(let error):
                        connectionLog("❌ [\(connectionId)] Connection failed: \(error)")
                        self.connectionState = .failed(error.localizedDescription)
                        self.currentCredentials = nil

                        // Ensure client is disconnected on failure to prevent stale
                        // state. The connect retry loop (handleConnection) owns the
                        // retry/surface decision, so we don't fire handleConnectionLost
                        // here (it would double-handle and could show the error mid-retry).
                        client.disconnect()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func cleanupExistingConnection() async {
        // Only pay the settle delay when there was actually a live connection to
        // tear down; a fresh connect shouldn't eat 0.2 s for nothing.
        let wasLive = connectionState != .disconnected
        // Tear down synchronously (we're on the MainActor): the nonisolated
        // disconnect() defers its state reset to a queued task, which would run
        // *after* connect() sets `.connecting`/`currentCredentials` and clobber
        // them mid-connect — leaving a connected manager with no credentials
        // (breaking shouldReconnect's reuse check and the transport fallback).
        disconnectNow()
        if wasLive {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        }
    }

    nonisolated func disconnect() {
        sshClient.disconnect()
        Task { @MainActor in
            self.finishDisconnectCleanup()
        }
    }

    @MainActor
    private func disconnectNow() {
        sshClient.disconnect()
        finishDisconnectCleanup()
    }

    @MainActor
    private func finishDisconnectCleanup() {
        // A connect() that started after this disconnect was issued owns the
        // state now — don't clobber its `.connecting`/credentials from a stale
        // queued cleanup (the transport itself was already torn down above).
        guard connectionState != .connecting else { return }
        connectionState = .disconnected
        currentCredentials = nil
        cancelBackgroundDisconnect()
        endBackgroundTask()
        stopHeartbeat()
    }
    
    deinit {
        sshClient.disconnect()
        backgroundDisconnectTimer?.cancel()
        pathMonitor?.cancel()
    }
    
    func shouldReconnect(host: String, username: String, password: String) -> Bool {
        guard case .connected = connectionState else { 
            return true 
        }
        
        // Check if we're already connected with the same credentials
        if let existing = currentCredentials,
           existing.host == host,
           existing.username == username,
           existing.password == password {
            connectionLog("✓ Using existing connection")
            return false
        }
        
        return true
    }
    
    /// Shared connection handler that manages common connection logic
    func handleConnection(
        host: String,
        username: String,
        password: String,
        onSuccess: @escaping () async -> Void,
        onError: @escaping (Error) -> Void
    ) {
        Task {
            if !shouldReconnect(host: host, username: username, password: password) {
                await onSuccess()
                return
            }

            // Retry a few times with short backoff before surfacing the error, so
            // a transient failure (e.g. Wi-Fi not fully re-associated on
            // foreground) self-heals instead of dead-ending on the first miss.
            var attempt = 0
            while true {
                attempt += 1
                do {
                    try await connect(host: host, username: username, password: password)
                    await onSuccess()
                    return
                } catch {
                    if attempt >= maxConnectAttempts {
                        connectionLog("❌ Connect failed after \(attempt) attempts: \(error.localizedDescription)")
                        onError(error)
                        return
                    }
                    connectionLog("↻ Connect attempt \(attempt) failed – retrying")
                    try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt)) // 0.5s, 1.0s…
                }
            }
        }
    }
    
    // Centralized connection loss detection (shared list lives on SSHError so
    // both transports and the manager can't drift apart).
    nonisolated func isConnectionLossError(_ error: Error) -> Bool {
        let isConnectionLoss = SSHError.isConnectionLoss(error)
        if isConnectionLoss {
            sshLog("🚨 Connection loss detected: \(error.localizedDescription.lowercased())")
        }
        return isConnectionLoss
    }

    /// Execute a command on a dedicated channel, watching failures for signs of
    /// connection loss. Timeout policy lives in the transport layer (the
    /// executor's per-command watchdog / the legacy per-channel timeout): a
    /// second timer here could only fire for a command that was legitimately
    /// queued behind slow AppleScript, declaring a live connection lost and
    /// then dropping the real result when it arrived.
    nonisolated func executeCommand(onChannel channelKey: String = "system", _ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        sshLog("→ [\(channelKey)] \(description ?? "command")")

        // Note activity so the heartbeat loop speeds up its pings (no Task hop).
        lastActivityAt = Date()

        let commandId = UUID().uuidString.prefix(8)
        let startTime = Date()

        client.executeCommandOnDedicatedChannel(channelKey, command, description: description) { [weak self] result in
            let elapsed = Date().timeIntervalSince(startTime)
            sshLog("⏰ [\(commandId)] Command completed in \(String(format: "%.1f", elapsed))s")

            switch result {
            case .success(let output):
                self?.noteCommandResponded()
                completion(.success(output))
            case .failure(let error):
                sshLog("❌ [\(commandId)] Command failed: \(error)")
                if self?.isConnectionLossError(error) == true {
                    sshLog("🚨 [\(commandId)] Connection loss detected during command execution")
                    Task { @MainActor [weak self] in
                        self?.handleConnectionLost()
                    }
                }
                completion(.failure(error))
            }
        }
    }
    
    /// Verifies that the connection is alive and responsive
    func verifyConnectionHealth() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            // Channels run an AppleScript interpreter, not a shell — use AppleScript.
            let token = ScriptTokens.healthCheck()
            let healthCommand = "return \"\(token)\""

            client.executeCommandOnDedicatedChannel("system", healthCommand, description: "Connection health check") { result in
                switch result {
                case .success(let output):
                    if output.contains(token) {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: SSHError.channelError("Invalid health check response"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - SSHClientProtocol Conformance
    
    /// Protocol-required connect method with completion handler
    nonisolated func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                try await self.connect(host: host, username: username, password: password)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    /// Protocol conformance – executes on a dedicated channel (default heartbeat behaviour)
    nonisolated func executeCommandOnDedicatedChannel(_ channelKey: String, _ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        // Note activity so the heartbeat loop speeds up its pings (no Task hop).
        lastActivityAt = Date()
        client.executeCommandOnDedicatedChannel(channelKey, command, description: description) { [weak self] result in
            if case .success = result {
                self?.noteCommandResponded()
            }
            completion(result)
        }
    }

    nonisolated func executeCommandIsolated(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        lastActivityAt = Date()
        client.executeCommandIsolated(command, description: description) { [weak self] result in
            if case .success = result {
                self?.noteCommandResponded()
            }
            completion(result)
        }
    }
}
