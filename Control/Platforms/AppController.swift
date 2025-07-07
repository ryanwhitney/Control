import SwiftUI

@MainActor
class AppController: ObservableObject {
    private var sshClient: SSHClientProtocol
    private var platformRegistry: PlatformRegistry
    private var isUpdating = false
    @Published var isActive = true
    
    // Add batch operation flag to reduce heartbeats
    private var isBatchOperation = false
    
    // Track initial comprehensive update completion
    @Published var hasCompletedInitialUpdate = false
    
    @Published var states: [String: AppState] = [:]
    @Published var lastKnownStates: [String: AppState] = [:]
    @Published var currentVolume: Float?
    
    // Track last per-platform state refresh to avoid redundant work/log noise
    private var lastStateRefresh: [String: Date] = [:]
    
    var platforms: [any AppPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClientProtocol, platformRegistry: PlatformRegistry) {
        appControllerLog("AppController: Initializing with \(platformRegistry.activePlatforms.count) active platforms")
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
        appControllerLog("AppController: Resetting state")
        isActive = true
        isUpdating = false
        hasCompletedInitialUpdate = false
    }
    
    func cleanup() {
        appControllerLog("AppController: Cleaning up")
        isActive = false
    }
    
    func updateClient(_ client: SSHClientProtocol) {
        appControllerLog("AppController: Updating SSH Client")
        self.sshClient = client
        isActive = true  // Ensure we're active for upcoming state updates
    }
    
    func updatePlatformRegistry(_ newRegistry: PlatformRegistry) {
        appControllerLog("AppController: Updating platform registry to \(newRegistry.activePlatforms.map { $0.name })")
        
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
        
        // Ensure controller is active for the new platforms
        isActive = true
    }
    
    func updateAllStates() async {
        appControllerLog("AppController: Starting comprehensive state update (\(platforms.count) platforms)")
        
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping state update")
            return
        }
        
        // If this is the initial update, give channels a moment to fully initialize
        if !hasCompletedInitialUpdate {
            // A shorter 0.5-second pause is typically enough for the dedicated
            // AppleScript channels to finish their interactive shell handshake.
            // Reducing this delay brings the system-volume fetch forward and
            // makes the UI feel snappier without sacrificing reliability.
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        // Mark as batch operation to reduce heartbeats
        isBatchOperation = true
        defer {
            isBatchOperation = false
            hasCompletedInitialUpdate = true
            appControllerLog("✓ State update complete")
        }
        
        // Update system volume first (sequential – very fast)
        await updateSystemVolume()
        
        // Fetch states for every platform in parallel so the phone waits for
        // just the slowest one instead of all in sequence.
        await withTaskGroup(of: Void.self) { group in
            for platform in platforms {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.updateState(for: platform)
                }
            }
        }
    }
    
    func updateState(for platform: any AppPlatform) async {
        guard isActive else { return }
        
        // Prevent duplicate refreshes within 2 s
        if let last = lastStateRefresh[platform.id], Date().timeIntervalSince(last) < 2 {
            return
        }
        lastStateRefresh[platform.id] = Date()
        
        let isRunning = await checkIfRunning(platform)
        guard isRunning else {
            let newState = AppState(
                title: "Not running",
                subtitle: "",
                isPlaying: nil,
                error: nil
            )
            // Only update if we don't have a previous state or if the state has changed
            let currentState = states[platform.id]
            let shouldUpdate = currentState == nil ||
                             currentState?.title != newState.title ||
                             currentState?.isPlaying != newState.isPlaying
            
            if shouldUpdate {
                states[platform.id] = newState
                lastKnownStates[platform.id] = newState
            }
            return
        }
        
        let result = await executeCommand(platform.fetchState(), channelKey: platform.id, description: "\(platform.id): fetch status")
        
        switch result {
        case .success(let output):
            
            if output.contains("Not authorized to send Apple events") {
                let newState = AppState(
                    title: "Permissions Required",
                    subtitle: "Grant permission in System Settings > Privacy > Automation",
                    isPlaying: nil,
                    error: nil
                )
                // Only update if we don't have a previous state or if the state has changed
                let currentState = states[platform.id]
                let shouldUpdate = currentState == nil ||
                                 currentState?.title != newState.title ||
                                 currentState?.isPlaying != newState.isPlaying
                
                if shouldUpdate {
                    states[platform.id] = newState
                    lastKnownStates[platform.id] = newState
                }
            } else {
                let newState = platform.parseState(output)
                appControllerLog("📊 \(platform.name) parsed state: title=[\(newState.title.redacted())], isPlaying=\(String(describing: newState.isPlaying))")
                
                // Only update if we don't have a previous state or if the state has changed
                let currentState = states[platform.id]
                let shouldUpdate = currentState == nil ||
                                 currentState?.title != newState.title ||
                                 currentState?.isPlaying != newState.isPlaying
                
                if shouldUpdate {
                    states[platform.id] = newState
                    lastKnownStates[platform.id] = newState
                }
            }
        case .failure(let error):
            appControllerLog("❌ \(platform.name) status fetch failed: \(error)")
            
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
    
    private func checkIfRunning(_ platform: any AppPlatform) async -> Bool {
        guard isActive else {
            return false
        }
        
        let result = await executeCommand(
            platform.isRunningScript(),
            channelKey: platform.id,
            description: "\(platform.id): check if running"
        )
        
        switch result {
        case .success(let output):
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let isRunning = trimmedOutput == "true" || trimmedOutput == "\"true\""
            appControllerLog("📊 \(platform.name) isRunning: \(isRunning)")
            return isRunning
        case .failure(let error):
            appControllerLog("❌ Failed to check if \(platform.name) is running: \(error)")
            return false
        }
    }
    
    func executeAction(platform: any AppPlatform, action: AppAction) async {
        guard isActive else { 
            appControllerLog("⚠️ Controller not active, skipping action")
            return 
        }
        
        // Leverage the shared helper on the platform to combine the action and
        // status script into a single AppleScript round-trip.
        let combinedScript = platform.actionWithStatus(action)
        
        let result = await executeCommand(combinedScript, channelKey: platform.id, description: "\(platform.id): \(action)")
        
        switch result {
        case .success(let output):
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
                appControllerLog("📊 \(platform.name) parsed state after action: title=[\(newState.title.redacted())], isPlaying=\(String(describing: newState.isPlaying))")
                states[platform.id] = newState
            }
        case .failure(let error):
            appControllerLog("❌ Action execution failed: \(error)")
            // Check if this is a connection loss and mark controller as inactive
            if let sshClient = self.sshClient as? SSHConnectionManager,
               sshClient.isConnectionLossError(error) {
                appControllerLog("🚨 Connection lost during action execution - marking controller inactive")
                self.isActive = false
                sshClient.handleConnectionLost()
            }
        }
    }
    
    func setVolume(_ volume: Float) async {
        guard isActive else { return }
        
        let target = Int(volume * 100)
        let script = "set volume output volume \(target)"
        let result = await executeCommand(script, channelKey: "system", description: "system: set volume to \(target)%")
        
        switch result {
        case .success(_):
            // Success is implied, no need to log
            break
        case .failure(let error):
            appControllerLog("❌ Failed to set volume: \(error)")
            // Check if this is a connection loss
            if let sshClient = self.sshClient as? SSHConnectionManager,
               sshClient.isConnectionLossError(error) {
                appControllerLog("🚨 Connection lost during volume change - marking controller inactive")
                self.isActive = false
                sshClient.handleConnectionLost()
            }
        }
    }
    
    private func updateSystemVolume() async {
        guard isActive else {
            return
        }
        
        let script = "output volume of (get volume settings)"

        let result = await executeCommand(script, channelKey: "system", description: "system: get volume")
        
        switch result {
        case .success(let output):
            if let volume = Float(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                currentVolume = volume / 100.0
                appControllerLog("✓ System volume: \(Int(volume))%")
            } else {
                appControllerLog("⚠️ Could not parse volume from output: '\(output)'")
                currentVolume = nil
            }
        case .failure(let error):
            appControllerLog("❌ Failed to get current volume: \(error)")
            currentVolume = nil
            
            // Check if this is a connection loss
            if let sshClient = self.sshClient as? SSHConnectionManager,
               sshClient.isConnectionLossError(error) {
                appControllerLog("🚨 Connection lost during volume update - marking controller inactive")
                self.isActive = false
                sshClient.handleConnectionLost()
            }
        }
    }
    
    // Keep this simpler version for single commands (permissions checks, etc)
    private func executeCommand(_ command: String, channelKey: String, description: String? = nil, bypassHeartbeat: Bool = false) async -> Result<String, Error> {
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping command")
            return .failure(SSHError.channelError("Controller not active"))
        }
        
        let wrappedCommand = ShellCommandUtilities.appleScriptForStreaming(command)
        
        return await withCheckedContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(returning: .failure(SSHError.channelError("AppController was deallocated")))
                return
            }
            
            self.sshClient.executeCommandOnDedicatedChannel(channelKey, wrappedCommand, description: description) { result in
                if case .failure(let error) = result {
                    appControllerLog("❌ Command failed: \(error)")
                    
                    // Check if this is a connection loss
                    if let connectionManager = self.sshClient as? SSHConnectionManager,
                       connectionManager.isConnectionLossError(error) {
                        appControllerLog("🚨 Connection appears to be lost - marking controller inactive")
                        self.isActive = false
                        connectionManager.handleConnectionLost()
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    private func updateStateIfChanged(_ platformId: String, _ newState: AppState) {
        // Only update if we don't have a previous state or if the state has changed
        if states[platformId]?.title != newState.title {
            states[platformId] = newState
            lastKnownStates[platformId] = newState
        }
    }
} 
