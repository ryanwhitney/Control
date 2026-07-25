import SwiftUI

@MainActor
class AppController: ObservableObject {
    private var sshClient: SSHClientProtocol
    private var platformRegistry: PlatformRegistry
    private var isUpdating = false
    @Published var isActive = true
    
    @Published var hasCompletedInitialUpdate = false
    
    @Published var states: [String: AppState] = [:]
    @Published var lastKnownStates: [String: AppState] = [:]
    @Published var currentVolume: Float?
    
    private var lastStateRefresh: [String: Date] = [:]
    
    private var lastActionTime: [String: Date] = [:]

    private var prefetchTask: Task<Void, Never>?

    var platforms: [any AppPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClientProtocol, platformRegistry: PlatformRegistry) {
        appControllerLog("Initializing with \(platformRegistry.activePlatforms.count) active platforms")
        self.sshClient = sshClient
        self.platformRegistry = platformRegistry
        resetPlatformStates()
    }

    private func resetPlatformStates() {
        states.removeAll()
        lastKnownStates.removeAll()
        for platform in platformRegistry.platforms {
            let initialState = AppState(title: "Loading...", subtitle: "")
            states[platform.id] = initialState
            lastKnownStates[platform.id] = initialState
        }
    }
    
    func reset() {
        appControllerLog("Resetting state")
        prefetchTask?.cancel()
        prefetchTask = nil
        isActive = true
        isUpdating = false
        hasCompletedInitialUpdate = false
        // A pre-drop refresh must not dedupe the first post-reconnect one.
        lastStateRefresh.removeAll()
        lastActionTime.removeAll()
    }

    func cleanup() {
        appControllerLog("Cleaning up")
        prefetchTask?.cancel()
        prefetchTask = nil
        isActive = false
    }
    
    func updateClient(_ client: SSHClientProtocol) {
        appControllerLog("Updating SSH Client")
        self.sshClient = client
        isActive = true  // Ensure we're active for upcoming state updates
    }
    
    func updatePlatformRegistry(_ newRegistry: PlatformRegistry) {
        appControllerLog("Updating platform registry to \(newRegistry.activePlatforms.map { $0.name })")
        self.platformRegistry = newRegistry
        resetPlatformStates()
        isActive = true
    }
    
    /// First refresh after a (re)connect, split by transport: streaming shares
    /// one channel, so a bulk sweep would queue behind itself and make swipes
    /// feel slow. Legacy is channel-per-command, so its global sweep is fine.
    func performInitialRefresh(visiblePlatformId: String?) async {
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping initial refresh")
            return
        }
        if sshClient.serializesAppCommands {
            // No warm-up sleep: ChannelExecutor fires its own on first use.
            // Volume and status are separate channels, so run them concurrently.
            let visible = visiblePlatformId.flatMap { id in platforms.first(where: { $0.id == id }) }
            if let visible {
                async let volume: Void = updateSystemVolume()
                async let status: Void = updateState(for: visible)
                _ = await (volume, status)
            } else {
                await updateSystemVolume()
            }
            hasCompletedInitialUpdate = true
            appControllerLog("✓ Initial visible-first refresh complete")
            prefetchBackgroundTabs(around: visiblePlatformId)
        } else {
            await updateAllStates(alwaysInclude: visiblePlatformId)
        }
    }

    /// Streaming only: fills the other tabs so swiping shows data instead of
    /// "Loading". One check at a time, nearest tab first, yielding between them
    /// so a user action is never behind more than one in-flight command.
    /// Foreground-only apps are skipped — they'd pop to the front off screen.
    func prefetchBackgroundTabs(around visiblePlatformId: String?) {
        prefetchTask?.cancel()
        // Legacy already populated every tab via its concurrent sweep.
        guard sshClient.serializesAppCommands, isActive else { return }

        let order = backgroundPrefetchOrder(around: visiblePlatformId)
        guard !order.isEmpty else { return }

        prefetchTask = Task { [weak self] in
            for platform in order {
                guard let self, self.isActive, !Task.isCancelled else { return }
                await self.updateState(for: platform)
                if Task.isCancelled { return }
                // Leave the channel idle so a user action slips in.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Background-checkable platforms except the visible one, nearest first.
    private func backgroundPrefetchOrder(around visiblePlatformId: String?) -> [any AppPlatform] {
        let center = platforms.firstIndex(where: { $0.id == visiblePlatformId }) ?? 0
        return platforms.enumerated()
            .filter { !$0.element.checksStatusOnlyWhenVisible && $0.element.id != visiblePlatformId }
            .sorted { abs($0.offset - center) < abs($1.offset - center) }
            .map { $0.element }
    }

    /// Refreshes volume and every platform's status. `checksStatusOnlyWhenVisible`
    /// platforms are excluded so a sweep never pops them to the front, except
    /// `alwaysInclude` — the tab on screen, refreshed first.
    func updateAllStates(alwaysInclude currentPlatformId: String? = nil) async {
        appControllerLog("❇︎ Starting update for \(platforms.count) platforms")

        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping state update")
            return
        }
        
        // Legacy's per-command channels need a moment on the first sweep.
        if !hasCompletedInitialUpdate && !sshClient.serializesAppCommands {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        await updateSystemVolume()

        // Foreground-only apps would pop to the front; keep the visible one.
        var platformsToCheck = platforms.filter {
            !$0.checksStatusOnlyWhenVisible || $0.id == currentPlatformId
        }
        // Paints before the rest on the sequential first sweep.
        if let idx = platformsToCheck.firstIndex(where: { $0.id == currentPlatformId }) {
            platformsToCheck.insert(platformsToCheck.remove(at: idx), at: 0)
        }

        // force: an explicit "Refresh All" or post-connect sweep must never be
        // deduped against a refresh from moments earlier.
        if hasCompletedInitialUpdate {
            await withTaskGroup(of: Void.self) { group in
                for platform in platformsToCheck {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.updateState(for: platform, force: true)
                    }
                }
            }
        } else {
            for platform in platformsToCheck {
                await updateState(for: platform, force: true)
            }
        }
        
        hasCompletedInitialUpdate = true
        appControllerLog("✓ State update complete")
    }
    
    func updateState(for platform: any AppPlatform, force: Bool = false) async {
        guard isActive else { return }

        if !force, let last = lastStateRefresh[platform.id], Date().timeIntervalSince(last) < 2 {
            appControllerLog("⏭️ \(platform.name): skipping refresh (< 2s since last)")
            return
        }
        lastStateRefresh[platform.id] = Date()

        appControllerLog("⚐ \(platform.name): checking status")

        let result = await executeCommand(platform.combinedStatusScript(), channelKey: platform.id, description: "\(platform.id): combined status")

        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == ScriptTokens.notRunning {
                updateStateIfChanged(platform.id, AppState(title: "Not running", subtitle: ""))
                return
            }

            if trimmed == ScriptTokens.accessibilityRequired {
                updateStateIfChanged(platform.id, Self.accessibilityRequiredState)
                return
            }

            if output.contains("Not authorized to send Apple events") {
                updateStateIfChanged(platform.id, Self.permissionsRequiredState)
            } else {
                let newState = platform.parseState(output)
                let playString = newState.isPlaying.map { $0 ? "playing" : "paused" } ?? "n/a"
                let subtitlePart = newState.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let subtitleSegment = subtitlePart.isEmpty ? "" : " · \(subtitlePart.redacted())"
                appControllerLog("⚑ \(platform.name) state: \(newState.title.redacted())\(subtitleSegment) · \(playString)")
                updateStateIfChanged(platform.id, newState)
            }
        case .failure(let error):
            appControllerLog("❌ \(platform.name) status fetch failed: \(error)")
            // Not "fresh": the next attempt must not be deduped against it.
            lastStateRefresh[platform.id] = nil

            if error.localizedDescription.contains("AppleScript error") {
                let newState = AppState(
                    title: "Script Error",
                    subtitle: "Unable to get status",
                    isPlaying: nil,
                    error: error.localizedDescription
                )
                states[platform.id] = newState
                lastKnownStates[platform.id] = newState
            } else {
                var currentState = states[platform.id] ?? AppState(title: "", subtitle: "error")
                currentState.error = error.localizedDescription
                states[platform.id] = currentState
                lastKnownStates[platform.id] = currentState
            }
        }
    }
    
    func executeActionWithStatus(platform: any AppPlatform, action: AppAction, isMenuAction: Bool = false) async {
        guard isActive else { 
            appControllerLog("⚠️ Controller not active, skipping action")
            return 
        }
        
        guard !isRateLimited(platform) else { return }

        appControllerLog("⚡︎ \(platform.name): \(action.label)")
        
        // Normal actions bundle action + status into one round-trip.
        let combinedScript = isMenuAction
            ? platform.executeMenuActionWithStatus(action)
            : platform.actionWithStatus(action)

        let result = await executeCommand(combinedScript, channelKey: platform.id, description: "\(platform.id): \(action)")

        switch result {
        case .success(let output):
            if output.trimmingCharacters(in: .whitespacesAndNewlines) == ScriptTokens.notRunning {
                updateStateIfChanged(platform.id, AppState(title: "Not running", subtitle: ""))
                return
            }
            let lines = output.components(separatedBy: .newlines)
            if let firstLine = lines.first,
               firstLine.contains("Not authorized to send Apple events") {
                appControllerLog("⚠️ Permission required for \(platform.name)")
                states[platform.id] = Self.permissionsRequiredState
            } else if let lastLine = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !lastLine.isEmpty {
                let newState = platform.parseState(lastLine)
                let playString = newState.isPlaying.map { $0 ? "playing" : "paused" } ?? "n/a"
                let subtitlePart = newState.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let subtitleSegment = subtitlePart.isEmpty ? "" : " · \(subtitlePart.redacted())"
                appControllerLog("❖ \(platform.name) after action: \(newState.title.redacted())\(subtitleSegment) · \(playString)")
                states[platform.id] = newState
            }
        case .failure(let error):
            // Connection-loss handling lives in executeCommand, which already
            // saw this error.
            appControllerLog("❌ Action execution failed: \(error)")
        }
    }

    /// An action's script alone — no status read appended. A bundled read sits in
    /// front of the *next* command too, throttling a burst of key presses to its
    /// rate; `updateState` refreshes the readout separately.
    ///
    /// Requires `executeAction` to be a *standalone* script, not a fragment meant
    /// for injection into a status tell (QuickTime, mpv, IINA).
    func executeActionWithoutStatus(platform: any AppPlatform, action: AppAction) async {
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping action")
            return
        }
        guard !isRateLimited(platform) else { return }

        appControllerLog("⚡︎ \(platform.name): \(action.label)")
        let result = await executeCommand(
            platform.executeAction(action),
            channelKey: platform.id,
            description: "\(platform.id): \(action.id)"
        )
        switch result {
        case .success(let output):
            // The one thing worth reading from a status-less action.
            if output.contains("Not authorized to send Apple events") {
                appControllerLog("⚠️ Automation permission required for \(platform.name)")
                states[platform.id] = Self.permissionsRequiredState
            } else if output.contains("not allowed to send keystrokes")
                        || output.contains("not allowed assistive access") {
                appControllerLog("⚠️ Accessibility permission required for \(platform.name)")
                states[platform.id] = Self.accessibilityRequiredState
            }
        case .failure(let error):
            // Connection-loss handling lives in executeCommand, which already
            // saw this error.
            appControllerLog("❌ Action execution failed: \(error)")
        }
    }

    /// Enforces `minActionInterval` for the platforms that declare one (TV's
    /// key-code actions can overload the channel), recording the send when it's
    /// allowed through. Shared by both action paths.
    private func isRateLimited(_ platform: any AppPlatform) -> Bool {
        let minInterval = platform.minActionInterval
        guard minInterval > 0 else { return false }
        if let lastAction = lastActionTime[platform.id],
           Date().timeIntervalSince(lastAction) < minInterval {
            appControllerLog("⏭️ \(platform.name): rate limiting action (< \(minInterval)s since last)")
            return true
        }
        lastActionTime[platform.id] = Date()
        return false
    }

    // MARK: - Volume

    private var pendingVolume: Float?
    private var volumeSendTask: Task<Void, Never>?
    private var lastVolumeSendAt = Date.distantPast
    /// Trailing-edge coalesced, so the latest value always wins and is always
    /// sent. The single rate limit for every caller; views just report values.
    private let volumeSendInterval: TimeInterval = 0.15

    func setVolume(_ volume: Float) {
        guard isActive else { return }
        pendingVolume = volume
        scheduleVolumeSendIfNeeded()
    }

    private func scheduleVolumeSendIfNeeded() {
        guard volumeSendTask == nil, pendingVolume != nil else { return }
        let wait = volumeSendInterval - Date().timeIntervalSince(lastVolumeSendAt)
        volumeSendTask = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard let self else { return }
            if let target = self.pendingVolume {
                self.pendingVolume = nil
                self.lastVolumeSendAt = Date()
                let percent = Int(target * 100)
                appControllerLog("🔊 Set volume request · \(percent)%")
                let result = await self.executeCommand("set volume output volume \(percent)", channelKey: "system", description: "system: set volume to \(percent)%")
                if case .failure(let error) = result {
                    appControllerLog("❌ Failed to set volume: \(error)")
                }
            }
            self.volumeSendTask = nil
            // A newer value may have arrived while the command was in flight.
            self.scheduleVolumeSendIfNeeded()
        }
    }

    private func updateSystemVolume() async {
        guard isActive else {
            return
        }
        
        appControllerLog("⚐ System: checking volume")
        
        let script = "output volume of (get volume settings)"

        let result = await executeCommand(script, channelKey: "system", description: "system: get volume")
        
        switch result {
        case .success(let output):
            if let volume = Float(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                currentVolume = volume / 100.0
                appControllerLog("⚑ System volume · \(Int(volume))%")
            } else {
                appControllerLog("⚠️ Could not parse volume from output: '\(output)'")
                currentVolume = nil
            }
        case .failure(let error):
            // Connection-loss handling lives in executeCommand, which already
            // saw this error.
            appControllerLog("❌ Failed to get current volume: \(error)")
            currentVolume = nil
        }
    }
    
    private func executeCommand(_ command: String, channelKey: String, description: String? = nil) async -> Result<String, Error> {
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping command")
            return .failure(SSHError.channelError("Controller not active"))
        }
        
        return await withCheckedContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(returning: .failure(SSHError.channelError("AppController was deallocated")))
                return
            }
            
            self.sshClient.executeCommandOnDedicatedChannel(channelKey, command, description: description) { result in
                if case .failure(let error) = result {
                    let commandDesc = description ?? "command"
                    appControllerLog("❌ SSH: \(commandDesc) failed - \(error)")
                    
                    if let connectionManager = self.sshClient as? SSHConnectionManager,
                       connectionManager.isConnectionLossError(error) {
                        appControllerLog("🚨 Connection lost - marking controller inactive")
                        self.isActive = false
                        connectionManager.handleConnectionLost(because: error)
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    /// No subtitle on either: the readout's "How to fix this" button carries the
    /// instructions, and `permissionKind` tells it which set to show.
    private static let permissionsRequiredState = AppState(
        title: "Permissions Required",
        subtitle: "",
        permissionKind: .automation
    )

    /// Synthesized keys need assistive access on top of Automation — a separate
    /// grant in a separate pane.
    private static let accessibilityRequiredState = AppState(
        title: "Permissions Required",
        subtitle: "",
        permissionKind: .accessibility
    )

    private func updateStateIfChanged(_ platformId: String, _ newState: AppState) {
        // Whole state, not just the title: a play/pause flip on the same track
        // changes only isPlaying, and would otherwise leave a stale icon.
        if states[platformId] != newState {
            states[platformId] = newState
            lastKnownStates[platformId] = newState
        }
    }
} 
