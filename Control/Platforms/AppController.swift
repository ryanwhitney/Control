import SwiftUI

@MainActor
class AppController: ObservableObject {
    private var sshClient: SSHClientProtocol
    private var platformRegistry: PlatformRegistry
    private var isUpdating = false
    @Published var isActive = true
    
    // Track initial comprehensive update completion
    @Published var hasCompletedInitialUpdate = false
    
    @Published var states: [String: AppState] = [:]
    @Published var lastKnownStates: [String: AppState] = [:]
    @Published var currentVolume: Float?
    
    // Track last per-platform state refresh to avoid redundant work/log noise
    private var lastStateRefresh: [String: Date] = [:]
    
    // Track last action per platform to prevent rapid-fire commands
    private var lastActionTime: [String: Date] = [:]

    // Background prefetch that fills the non-visible tabs on the streaming
    // transport (see `prefetchBackgroundTabs`). One at a time, cancellable.
    private var prefetchTask: Task<Void, Never>?

    var platforms: [any AppPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClientProtocol, platformRegistry: PlatformRegistry) {
        appControllerLog("Initializing with \(platformRegistry.activePlatforms.count) active platforms")
        self.sshClient = sshClient
        self.platformRegistry = platformRegistry
        
        // Initialize states
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
        // Forget refresh/action timestamps: after a reconnect the on-screen data
        // may be stale, and a pre-drop refresh must not dedupe the first
        // post-reconnect one.
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
        
        // Clear existing states
        states.removeAll()
        lastKnownStates.removeAll()
        
        // Initialize states for new platforms
        for platform in platformRegistry.platforms {
            let initialState = AppState(title: "Loading...", subtitle: "")
            states[platform.id] = initialState
            lastKnownStates[platform.id] = initialState
        }
        
        isActive = true
    }
    
    /// First refresh after a (re)connect. Chosen by transport so we don't hog a
    /// serial channel: on streaming (`serializesAppCommands`) all app commands
    /// share one channel, so a bulk sweep would queue behind itself and make
    /// swipes feel slow — refresh only the visible tab and let the rest load
    /// lazily as you navigate. On legacy (channel-per-command, concurrent) the
    /// existing global sweep is fine and stays unchanged.
    func performInitialRefresh(visiblePlatformId: String?) async {
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping initial refresh")
            return
        }
        if sshClient.serializesAppCommands {
            // No warm-up sleep: the app channel's ChannelExecutor waits for its
            // interactive shell and fires its own warm-up round-trip on first use.
            // Volume (system channel) and the visible tab's status (app-0 channel)
            // are independent round-trips, so run them concurrently to save an RTT.
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
            // Fill the remaining tabs in the background, nearest-first.
            prefetchBackgroundTabs(around: visiblePlatformId)
        } else {
            await updateAllStates(alwaysInclude: visiblePlatformId)
        }
    }

    /// Streaming only: proactively refresh the *other* tabs so swiping shows data
    /// instead of "Loading", without the contention a bulk sweep would cause on
    /// the serial app channel. Runs one check at a time, ordered by distance from
    /// the visible tab (nearest first, expanding out), yielding the channel
    /// between checks so a swipe or action is only ever behind ≤1 in-flight
    /// command. Re-centers (cancel + restart) whenever the visible tab changes.
    /// Foreground-only apps (IINA/mpv) are never prefetched — they'd pop to the
    /// front off screen — and the visible tab is refreshed separately.
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
                // Gentle spacing: leave the channel idle between checks so a
                // user action/swipe slips in rather than queueing behind prefetch.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Background-checkable platforms except the visible one, ordered by tab
    /// distance from it (nearest first).
    private func backgroundPrefetchOrder(around visiblePlatformId: String?) -> [any AppPlatform] {
        let center = platforms.firstIndex(where: { $0.id == visiblePlatformId }) ?? 0
        return platforms.enumerated()
            .filter { !$0.element.checksStatusOnlyWhenVisible && $0.element.id != visiblePlatformId }
            .sorted { abs($0.offset - center) < abs($1.offset - center) }
            .map { $0.element }
    }

    /// Refreshes system volume and every platform's status. Platforms that must
    /// foreground the Mac app to read status (`checksStatusOnlyWhenVisible`) are
    /// excluded so a bulk refresh never pops them to the front — except the one
    /// named by `alwaysInclude` (the tab currently on screen), which is refreshed
    /// first so it shows status immediately.
    func updateAllStates(alwaysInclude currentPlatformId: String? = nil) async {
        appControllerLog("❇︎ Starting update for \(platforms.count) platforms")

        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping state update")
            return
        }
        
        // Legacy-only warm-up pause: give its per-command channels a moment to
        // settle on the very first sweep. Streaming skips this — it refreshes
        // visible-first via `performInitialRefresh` and never reaches here cold,
        // and the ChannelExecutor does its own per-channel warm-up round-trip.
        if !hasCompletedInitialUpdate && !sshClient.serializesAppCommands {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        // Update system volume first (sequential – very fast)
        await updateSystemVolume()

        // Exclude foreground-only apps (IINA/mpv) from the bulk sweep so they
        // don't pop to the front; keep the currently-visible one so it refreshes.
        var platformsToCheck = platforms.filter {
            !$0.checksStatusOnlyWhenVisible || $0.id == currentPlatformId
        }
        // Refresh the visible tab first so it paints before the rest (matters on
        // the legacy sequential first sweep and on a Fast "Refresh All").
        if let idx = platformsToCheck.firstIndex(where: { $0.id == currentPlatformId }) {
            platformsToCheck.insert(platformsToCheck.remove(at: idx), at: 0)
        }

        // Slow-start strategy: the very first comprehensive refresh runs
        // (force: an explicit "Refresh All" or post-connect sweep must never be
        // silently deduped against a refresh from moments earlier).
        if hasCompletedInitialUpdate {
            // Parallel path – after the initial warm-up everything is fast again.
            await withTaskGroup(of: Void.self) { group in
                for platform in platformsToCheck {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.updateState(for: platform, force: true)
                    }
                }
            }
        } else {
            // Initial sweep: do one platform at a time.
            for platform in platformsToCheck {
                await updateState(for: platform, force: true)
            }
        }
        
        hasCompletedInitialUpdate = true
        appControllerLog("✓ State update complete")
    }
    
    func updateState(for platform: any AppPlatform, force: Bool = false) async {
        guard isActive else { return }

        // Prevent duplicate refreshes within 2 s
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

            // Detect sentinel for not-running state
            if trimmed == ScriptTokens.notRunning {
                let newState = AppState(
                    title: "Not running",
                    subtitle: "",
                    isPlaying: nil,
                    error: nil
                )
                updateStateIfChanged(platform.id, newState)
                return
            }
            
            if output.contains("Not authorized to send Apple events") {
                let newState = AppState(
                    title: "Permissions Required",
                    subtitle: "Grant permission in System Settings > Privacy > Automation",
                    isPlaying: nil,
                    error: nil
                )
                updateStateIfChanged(platform.id, newState)
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
            // A failed fetch shouldn't count as "fresh": let the next attempt
            // (e.g. right after an auto-reconnect) run instead of deduping it.
            lastStateRefresh[platform.id] = nil

            // For AppleScript errors, show a more user-friendly message
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
                // For other errors, we might want to keep the previous state and just add an error
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
        
        // Rate limit actions for platforms that declare a minimum interval
        // (e.g. TV's key-code driven actions can overload the channel).
        let minInterval = platform.minActionInterval
        if minInterval > 0 {
            if let lastAction = lastActionTime[platform.id],
               Date().timeIntervalSince(lastAction) < minInterval {
                appControllerLog("⏭️ \(platform.name): rate limiting action (< \(minInterval)s since last)")
                return
            }
            lastActionTime[platform.id] = Date()
        }
        
        appControllerLog("⚡︎ \(platform.name): \(action.label)")
        
        // Menu actions (e.g. Close App) have their own script; normal actions
        // combine the action + status into a single AppleScript round-trip.
        let combinedScript = isMenuAction
            ? platform.executeMenuActionWithStatus(action)
            : platform.actionWithStatus(action)

        let result = await executeCommand(combinedScript, channelKey: platform.id, description: "\(platform.id): \(action)")

        switch result {
        case .success(let output):
            // Menu actions like Close App report the app is gone via this sentinel.
            if output.trimmingCharacters(in: .whitespacesAndNewlines) == ScriptTokens.notRunning {
                updateStateIfChanged(platform.id, AppState(title: "Not running", subtitle: "", isPlaying: nil, error: nil))
                return
            }
            let lines = output.components(separatedBy: .newlines)
            if let firstLine = lines.first,
               firstLine.contains("Not authorized to send Apple events") {
                appControllerLog("⚠️ Permission required for \(platform.name)")
                states[platform.id] = AppState(
                    title: "Permissions Required",
                    subtitle: "Grant permission in System Settings > Privacy > Automation",
                    isPlaying: nil,
                    error: nil
                )
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

    // MARK: - Volume

    private var pendingVolume: Float?
    private var volumeSendTask: Task<Void, Never>?
    private var lastVolumeSendAt = Date.distantPast
    /// At most one volume command per interval, trailing-edge coalesced: the
    /// latest value always wins and is always sent. This is the single rate
    /// limit for every caller (slider, buttons, future shortcuts) — the views
    /// just report values.
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
                    
                    // Check if this is a connection loss
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
    
    private func updateStateIfChanged(_ platformId: String, _ newState: AppState) {
        // Compare the whole state, not just the title — a play/pause flip on the
        // same track changes isPlaying/subtitle but not the title, and would
        // otherwise be dropped, leaving a stale icon.
        if states[platformId] != newState {
            states[platformId] = newState
            lastKnownStates[platformId] = newState
        }
    }
} 
