import Foundation
import SwiftUI
import Network

@MainActor
class SSHConnectionManager: ObservableObject, SSHClientProtocol {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    private nonisolated let sshClient: SSHClient
    private var currentCredentials: Credentials?
    private var connectionLostHandler: (@MainActor (Error?) -> Void)?
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "SSHPathMonitor")
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // MARK: - Heartbeat Management
    private var heartbeatTask: Task<Void, Never>?
    private var consecutiveHeartbeatFailures = 0
    private let maxHeartbeatFailures = 1
    private let minHeartbeatInterval: TimeInterval = 0.5
    private let maxHeartbeatInterval: TimeInterval = 12
    private var currentHeartbeatInterval: TimeInterval = 3
    private var lastHeartbeatSuccess: Date?
    private var recoveryDeadline: Date?
    private var heartbeatCounter: UInt32 = 0
    private let heartbeatReplyTimeout: TimeInterval = 1.0
    
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
            if path.status != .satisfied {
                connectionLog("🚨 Network path no longer satisfied – assuming connection lost")
                Task { @MainActor in
                    self.handleConnectionLost(because: path.status == .unsatisfied ? SSHError.connectionFailed("Network path unavailable") : nil)
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    func setConnectionLostHandler(_ handler: @escaping @MainActor (Error?) -> Void) {
        self.connectionLostHandler = handler
    }
    
    nonisolated var client: SSHClient { 
        // Accessor no longer logs every call to reduce console noise.
        return sshClient 
    }
    
    func handleConnectionLost(because error: Error? = nil) {
        Task { @MainActor in
            // Prevent multiple simultaneous reconnect attempts
            guard connectionState == .connected || connectionState == .recovering else { return }
            
            connectionLog("🚨 Connection lost...")
            
            // Immediately transition to disconnected to stop further commands
            self.connectionState = .disconnected
            
            // Clean up old connection artifacts
            self.sshClient.disconnect()
            
            // Trigger UI handler to show alert
            self.connectionLostHandler?(error)
            
            // Stop heartbeat monitoring
            self.stopHeartbeat()
        }
    }
    
    func connect(host: String, username: String, password: String) async throws {
        connectionLog("SSHConnectionManager: Connection Request")
        
        // Show connection metadata without exposing sensitive info
        let isLocal = host.contains(".local")
        let connectionType = isLocal ? "Bonjour (.local)" : "TCP/IP"
        let hostRedacted = String(host.prefix(3)) + "***"
        
        connectionLog("Connecting via \(connectionType) to \(hostRedacted)")
        
        // Always clean up first to prevent state corruption
        await cleanupExistingConnection()
        
        connectionState = .connecting
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
                    connectionLog("🔄 [\(connectionId)] Processing connection result: \(result)")
                    
                    switch result {
                    case .success:
                        connectionLog("✓ [\(connectionId)] Connection successful")
                        self.connectionState = .connected
                        // Start heartbeat monitoring once connected
                        self.startHeartbeat()
                        self.consecutiveHeartbeatFailures = 0
                        self.lastHeartbeatSuccess = Date()
                        self.recoveryDeadline = nil
                        continuation.resume()
                    case .failure(let error):
                        connectionLog("❌ [\(connectionId)] Connection failed: \(error)")
                        self.connectionState = .failed(error.localizedDescription)
                        self.currentCredentials = nil
                        
                        // Ensure client is disconnected on failure to prevent stale state
                        client.disconnect()
                        self.handleConnectionLost(because: error)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    func verifyConnection(host: String, username: String, password: String) async throws {
        try await connect(host: host, username: username, password: password)
    }
    
    private func cleanupExistingConnection() async {
        disconnect()
        // Give a small delay to ensure cleanup
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
    }
    
    nonisolated func disconnect() {
        sshClient.disconnect()
        Task { @MainActor in
            self.connectionState = .disconnected
            self.currentCredentials = nil
            self.cancelBackgroundDisconnect()
            self.endBackgroundTask()
            // Stop heartbeat monitoring
            self.stopHeartbeat()
        }
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
    
    // MARK: - Lifecycle Management
    
    private var backgroundDisconnectTimer: DispatchWorkItem?
    private var lastScenePhaseChange: (from: ScenePhase, to: ScenePhase, time: Date)?
    
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        // Debounce duplicate calls (multiple views calling this simultaneously)
        let now = Date()
        if let last = lastScenePhaseChange,
           last.from == oldPhase && last.to == newPhase,
           now.timeIntervalSince(last.time) < 0.1 {
            return // Ignore duplicate call within 100ms
        }
        
        lastScenePhaseChange = (oldPhase, newPhase, now)
        connectionLog("Scene phase: \(oldPhase) -> \(newPhase)")
        
        switch newPhase {
        case .active:
            cancelBackgroundDisconnect()
            endBackgroundTask()
        case .inactive:
            // No action needed, keep connection alive briefly
            break
        case .background:
            startBackgroundDisconnectTimer()
        @unknown default:
            connectionLog("Unknown scene phase: \(newPhase)")
        }
    }
    
    private func startBackgroundDisconnectTimer() {
        // Cancel any existing timer
        cancelBackgroundDisconnect()
        
        // Start background task to prevent immediate termination
        startBackgroundTask()
        
        // Set up 30-second timer to disconnect SSH
        let disconnectTimer = DispatchWorkItem { [weak self] in
            connectionLog("📱 App backgrounded for 30 seconds - disconnecting SSH")
            self?.disconnect()
            self?.endBackgroundTask()
        }
        
        backgroundDisconnectTimer = disconnectTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: disconnectTimer)
        connectionLog("📱 Started 30-second background disconnect timer")
    }
    
    private func cancelBackgroundDisconnect() {
        backgroundDisconnectTimer?.cancel()
        backgroundDisconnectTimer = nil
        connectionLog("📱 Cancelled background disconnect timer")
    }
    
    private func startBackgroundTask() {
        // End any existing background task first
        endBackgroundTask()
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SSH Connection Cleanup") { [weak self] in
            // Background task is about to expire (system limit ~30-180 seconds)
            connectionLog("📱 Background task expiring - disconnecting SSH")
            self?.client.disconnect()
            self?.disconnect() 
            self?.endBackgroundTask()
        }
        
        if backgroundTask == .invalid {
            connectionLog("⚠️ Failed to start background task")
        } else {
            connectionLog("📱 Started background task: \(backgroundTask)")
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            connectionLog("📱 Ending background task: \(backgroundTask)")
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
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
            do {
                if !shouldReconnect(host: host, username: username, password: password) {
                    await onSuccess()
                    return
                }
                
                try await connect(host: host, username: username, password: password)
                await onSuccess()
            } catch {
                onError(error)
            }
        }
    }
    
    // Centralized connection loss detection
    nonisolated func isConnectionLossError(_ error: Error) -> Bool {
        let errorString = error.localizedDescription.lowercased()
        let isConnectionLoss = errorString.contains("connection lost") ||
               errorString.contains("eof") ||
               errorString.contains("connection reset") ||
               errorString.contains("broken pipe") ||
               errorString.contains("connection closed") ||
               errorString.contains("tcp shutdown") ||
               errorString.contains("network is unreachable") ||
               errorString.contains("host is unreachable") ||
               errorString.contains("connection timed out") ||
               errorString.contains("no route to host")
        
        if isConnectionLoss {
            sshLog("🚨 Connection loss detected: \(errorString)")
        }
        
        return isConnectionLoss
    }
    
    /// Execute a command with proactive timeout-based connection monitoring, allowing selection of a dedicated channel.
    nonisolated func executeCommand(onChannel channelKey: String = "system", _ command: String, description: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        sshLog("SSHConnectionManager: Executing command on channel \(channelKey)")
        if let description = description {
            sshLog("Command: \(description)")
        }
        
        // Boost heartbeat frequency after user/system activity
        Task { @MainActor in
            self.resetHeartbeatInterval()
        }
        
        let commandId = UUID().uuidString.prefix(8)
        var hasCompleted = false
        let startTime = Date()
        
        // Start proactive timeout monitoring
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard !hasCompleted else { return }
            hasCompleted = true
            
            let elapsed = Date().timeIntervalSince(startTime)
            sshLog("⏰ [\(commandId)] Command timed out after \(String(format: "%.1f", elapsed))s with no response")
            
            // Connection appears dead - trigger reconnection
            Task { @MainActor [weak self] in
                self?.handleConnectionLost()
            }
            completion(.failure(SSHError.timeout))
        }
        
        let timeoutSeconds: Double = 15.0
        sshLog("⏰ [\(commandId)] Starting \(Int(timeoutSeconds))-second timeout monitor")
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutTask)
        
        // Execute the command on dedicated channel WITHOUT heartbeat verification
        // Heartbeats were causing channel exhaustion and connection failures
        client.executeCommandOnDedicatedChannel(channelKey, command, description: description) { [weak self] result in
            guard !hasCompleted else { 
                sshLog("⚠️ [\(commandId)] Command completed but timeout already triggered, ignoring result")
                return 
            }
            hasCompleted = true
            timeoutTask.cancel()
            
            let elapsed = Date().timeIntervalSince(startTime)
            sshLog("⏰ [\(commandId)] Command completed in \(String(format: "%.1f", elapsed))s")
            
            switch result {
            case .success(let output):
                sshLog("✓ [\(commandId)] Command succeeded")
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
            let healthCommand = "echo \"health-check-$(date +%s)\""
            
            client.executeCommandOnDedicatedChannel("system", healthCommand, description: "Connection health check") { result in
                switch result {
                case .success(let output):
                    if output.contains("health-check-") {
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
        // User/system activity detected – reset heartbeat interval to minimum
        Task { @MainActor in
            self.resetHeartbeatInterval()
        }
        client.executeCommandOnDedicatedChannel(channelKey, command, description: description, completion: completion)
    }
    
    // MARK: - Heartbeat Helpers
    private func startHeartbeat() {
        stopHeartbeat()
        consecutiveHeartbeatFailures = 0
        currentHeartbeatInterval = minHeartbeatInterval
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.performHeartbeat() // immediate first ping
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.currentHeartbeatInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.performHeartbeat()
                // Gradually back off interval until max
                self.currentHeartbeatInterval = min(self.currentHeartbeatInterval + 1, self.maxHeartbeatInterval)
            }
        }
        connectionLog("🔄 Heartbeat started (interval \(minHeartbeatInterval)s -> \(maxHeartbeatInterval)s)")
        
        lastHeartbeatSuccess = Date()
        recoveryDeadline = nil
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        connectionLog("⏹️ Heartbeat stopped")
        recoveryDeadline = nil
    }

    @MainActor
    private func performHeartbeat() async {
        // Build unique identifier & script
        let hbId = heartbeatCounter
        heartbeatCounter &+= 1
        let idString = String(format: "HB%05u", hbId)
        let script = "return \"\(idString)\""
        let sendTime = Date()
        var completed = false

        // Timeout watchdog
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard let self, !completed else { return }
            completed = true
            self.handleHeartbeatFailure(reason: "timeout waiting > \(heartbeatReplyTimeout)s for \(idString)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + heartbeatReplyTimeout, execute: timeoutTask)

        self.client.executeCommandOnDedicatedChannel("heartbeat", script, description: "heartbeat-\(idString)") { [weak self] result in
            guard let self, !completed else { return }
            completed = true
            timeoutTask.cancel()

            switch result {
            case .success(let output):
                if output.contains(idString) {
                    self.handleHeartbeatSuccess(rtt: Date().timeIntervalSince(sendTime), id: idString)
                } else {
                    self.handleHeartbeatFailure(reason: "mismatched reply for \(idString)")
                }
            case .failure(let error):
                self.handleHeartbeatFailure(reason: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func handleHeartbeatSuccess(rtt: TimeInterval, id: String) {
        consecutiveHeartbeatFailures = 0
        lastHeartbeatSuccess = Date()
        if connectionState == .recovering {
            connectionState = .connected
            connectionLog("✅ Recovery complete – connection restored (\(String(format: "%.0f", rtt*1000)) ms)")
        } else {
            connectionLog("✓ Heartbeat OK (\(id), \(String(format: "%.0f", rtt*1000)) ms)")
        }
        recoveryDeadline = nil
    }

    @MainActor
    private func handleHeartbeatFailure(reason: String) {
        consecutiveHeartbeatFailures += 1
        connectionLog("⚠️ Heartbeat failure (#\(consecutiveHeartbeatFailures)): \(reason)")
        if consecutiveHeartbeatFailures == 1 {
            connectionState = .recovering
            recoveryDeadline = Date().addingTimeInterval(2)
            currentHeartbeatInterval = 0.5
            connectionLog("🛠️ Entering recovering state – monitoring for 2s")
        } else {
            let shouldDrop = consecutiveHeartbeatFailures >= maxHeartbeatFailures && (recoveryDeadline.map { Date() >= $0 } ?? false)
            if shouldDrop {
                connectionLog("🚨 Recovery failed – treating as connection loss")
                handleConnectionLost()
                stopHeartbeat()
            }
        }
    }

    @MainActor
    private func resetHeartbeatInterval() {
        currentHeartbeatInterval = minHeartbeatInterval
    }
} 
