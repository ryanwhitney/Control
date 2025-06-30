import SwiftUI

@MainActor
class AppController: ObservableObject {
    private var sshClient: SSHClientProtocol
    private var platformRegistry: PlatformRegistry
    private var isUpdating = false
    @Published var isActive = true
    static var debugMode = true // Add debug flag for troubleshooting
    
    @Published var states: [String: AppState] = [:]
    @Published var lastKnownStates: [String: AppState] = [:]
    @Published var currentVolume: Float?
    
    var platforms: [any AppPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClientProtocol, platformRegistry: PlatformRegistry) {
        appControllerLog("AppController: Initializing")
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
        // Don't reset states - they'll update naturally when we get new data
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
        appControllerLog("AppController: Updating platform registry")
        appControllerLog("Previous platform count: \(platformRegistry.platforms.count)")
        appControllerLog("New platform count: \(newRegistry.platforms.count)")
        
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
        appControllerLog("✓ AppController reactivated for new platform registry")
        
        appControllerLog("✓ Platform registry updated with platforms: \(platformRegistry.platforms.map { $0.name })")
    }
    
    func updateAllStates() async {
        appControllerLog("AppController: Starting comprehensive state update")
        appControllerLog("Controller active: \(isActive)")
        appControllerLog("Number of platforms: \(platforms.count)")
        
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping state update")
            return
        }
        
        // Update system volume first
        await updateSystemVolume()
        
        // Then check which apps are running
        for platform in platforms {
            guard isActive else { 
                appControllerLog("⚠️ Controller became inactive during updates, stopping")
                break 
            }
            
            appControllerLog("Checking platform: \(platform.name)")
            let isRunning = await checkIfRunning(platform)
            if isRunning {
                appControllerLog("✓ \(platform.name) is running, fetching state")
                await updateState(for: platform)
            } else {
                appControllerLog("\(platform.name) is not running")
                let newState = AppState(
                    title: "Not running",
                    subtitle: "",
                    isPlaying: nil,
                    error: nil
                )
                updateStateIfChanged(platform.id, newState)
            }
        }
        
        appControllerLog("✓ State update complete")
    }
    
    func updateState(for platform: any AppPlatform) async {
        guard isActive else { return }
        
        let isRunning = await checkIfRunning(platform)
        guard isRunning else {
            let newState = AppState(
                title: "Not running",
                subtitle: "",
                isPlaying: nil,
                error: nil
            )
            // Only update if we don't have a previous state or if the state has changed
            if states[platform.id]?.title != newState.title {
                states[platform.id] = newState
                lastKnownStates[platform.id] = newState
            }
            return
        }
        
        let result = await executeCommand(platform.fetchState(), description: "\(platform.name): fetch status")
        
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
                if states[platform.id]?.title != newState.title {
                    states[platform.id] = newState
                    lastKnownStates[platform.id] = newState
                }
            } else {
                let newState = platform.parseState(output)
                // Only update if we don't have a previous state or if the state has changed
                if states[platform.id]?.title != newState.title {
                    states[platform.id] = newState
                    lastKnownStates[platform.id] = newState
                }
            }
        case .failure(let error):
            // For errors, we might want to keep the previous state and just add an error
            var currentState = states[platform.id] ?? AppState(title: "", subtitle: "error")
            currentState.error = error.localizedDescription
            states[platform.id] = currentState
            lastKnownStates[platform.id] = currentState
        }
    }
    
    private func checkIfRunning(_ platform: any AppPlatform) async -> Bool {
        appControllerLog("AppController: Checking if \(platform.name) is running")
        guard isActive else {
            appControllerLog("⚠️ Controller not active, returning false")
            return false
        }
        
        let result = await executeCommand(
            platform.isRunningScript(),
            description: "\(platform.name): check if running"
        )
        
        switch result {
        case .success(let output):
            let isRunning = output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            appControllerLog(isRunning ? "✓ \(platform.name) is running" : "⚠️ \(platform.name) is not running")
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
        
        appControllerLog("AppController: Executing action \(action) on \(platform.name)")
        
        // Combine action and status fetch into single script
        let actionScript = platform.executeAction(action)
        let statusScript = platform.fetchState()
        
        let combinedScript = """
        try
            \(actionScript)
            delay 0.1
            \(statusScript)
        on error errMsg
            delay 0.1
            \(statusScript)
        end try
        """
        
        let result = await executeCommand(combinedScript, description: "\(platform.name): executeAction(.\(action))")
        
        switch result {
        case .success(let output):
            appControllerLog("✓ Action executed successfully")
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
                appControllerLog("State updated for \(platform.name)")
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
        appControllerLog("AppController: Setting system volume to \(Int(volume * 100))%")
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping volume change")
            return
        }
        
        let script = "set volume output volume \(Int(volume * 100))"
        let result = await executeCommand(script, description: "System: set volume(\(Int(volume * 100)))")
        
        switch result {
        case .success(let output):
            appControllerLog("✓ Volume set successfully")
            if !output.isEmpty {
                appControllerLog("Volume command output: \(output)")
            }
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
        appControllerLog("AppController: Updating system volume")
        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping volume update")
            return
        }
        
        let script = """
        output volume of (get volume settings)
        """
        
        let result = await executeCommand(script, description: "System: get volume")
        
        switch result {
        case .success(let output):
            if let volume = Float(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                currentVolume = volume / 100.0
                appControllerLog("✓ Current volume: \(Int(volume))%")
                appControllerLog("Volume controls should now be enabled")
            } else {
                appControllerLog("⚠️ Could not parse volume from output: '\(output)'")
                appControllerLog("🚨 Volume controls will remain disabled due to parse failure")
                currentVolume = nil
            }
        case .failure(let error):
            appControllerLog("❌ Failed to get current volume: \(error)")
            appControllerLog("🚨 Volume controls will remain disabled due to command failure")
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
    private func executeCommand(_ command: String, description: String? = nil) async -> Result<String, Error> {
        if let description = description {
            appControllerLog("Executing command: \(description)")
        } else {
            appControllerLog("Executing command")
        }

        guard isActive else {
            appControllerLog("⚠️ Controller not active, skipping command")
            return .failure(SSHError.channelError("Controller not active"))
        }
        
        let wrappedCommand = ShellCommandUtilities.wrapAppleScriptForBash(command)
        
        return await withCheckedContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(returning: .failure(SSHError.channelError("AppController was deallocated")))
                return
            }
            
            // Always use new channel for reliability - revert the session reuse optimization
            self.sshClient.executeCommandWithNewChannel(wrappedCommand, description: description) { result in
                switch result {
                case .success(let output):
                    appControllerLog("✓ Command executed successfully")
                    if !output.isEmpty {
                        appControllerLog("Command output: \(output)")
                    }
                    continuation.resume(returning: result)
                case .failure(let error):
                    appControllerLog("❌ Command failed: \(error)")
                    
                    // Check if this is a connection loss
                    if let connectionManager = self.sshClient as? SSHConnectionManager,
                       connectionManager.isConnectionLossError(error) {
                        appControllerLog("🚨 Connection appears to be lost - marking controller inactive")
                        self.isActive = false  // Prevent further commands
                        connectionManager.handleConnectionLost()
                    }
                    
                    continuation.resume(returning: result)
                }
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
