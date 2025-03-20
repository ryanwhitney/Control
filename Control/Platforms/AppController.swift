import SwiftUI

@MainActor
class AppController: ObservableObject {
    private var sshClient: SSHClientProtocol
    private let platformRegistry: PlatformRegistry
    private var isUpdating = false
    private var isActive = true
    
    @Published var states: [String: AppState] = [:]
    @Published var lastKnownStates: [String: AppState] = [:]
    @Published var currentVolume: Float?
    
    var platforms: [any AppPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClientProtocol, platformRegistry: PlatformRegistry) {
        print("\n=== AppController: Initializing ===")
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
        print("\n=== AppController: Resetting ===")
        isActive = true
        isUpdating = false
        // Don't reset states - they'll update naturally when we get new data
    }
    
    func cleanup() {
        print("\n=== AppController: Cleaning up ===")
        isActive = false
    }
    
    func updateClient(_ client: SSHClientProtocol) {
        print("\n=== AppController: Updating SSH Client ===")
        self.sshClient = client
        isActive = true  // Ensure we're active for upcoming state updates
    }
    
    func updateAllStates() async {
        print("\n=== AppController: Updating All States ===")
        guard isActive else {
            print("⚠️ Controller not active, skipping update")
            return
        }
        
        // Update system volume first
        await updateSystemVolume()
        
        // Then check which apps are running
        for platform in platforms {
            guard isActive else { 
                print("⚠️ Controller became inactive, stopping updates")
                break 
            }
            
            print("\nChecking platform: \(platform.name)")
            let isRunning = await checkIfRunning(platform)
            if isRunning {
                print("✓ \(platform.name) is running, updating state")
                await updateState(for: platform)
            } else {
                print("⚠️ \(platform.name) is not running")
                let newState = AppState(
                    title: "",
                    subtitle: "Not Running",
                    isPlaying: nil,
                    error: nil
                )
                updateStateIfChanged(platform.id, newState)
            }
        }
    }
    
    func updateState(for platform: any AppPlatform) async {
        guard isActive else { return }
        
        let isRunning = await checkIfRunning(platform)
        guard isRunning else {
            let newState = AppState(
                title: "",
                subtitle: "Not Running",
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
        print("\n=== AppController: Checking if \(platform.name) is running ===")
        guard isActive else {
            print("⚠️ Controller not active, returning false")
            return false
        }
        
        let result = await executeCommand(
            platform.isRunningScript(),
            description: "\(platform.name): check if running"
        )
        
        switch result {
        case .success(let output):
            let isRunning = output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            print(isRunning ? "✓ App is running" : "⚠️ App is not running")
            return isRunning
        case .failure:
            print("❌ Failed to check if running")
            return false
        }
    }
    
    func executeAction(platform: any AppPlatform, action: AppAction) async {
        guard isActive else { return }
        
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
        
        if case .success(let output) = result {
            let lines = output.components(separatedBy: .newlines)
            if let firstLine = lines.first,
               firstLine.contains("Not authorized to send Apple events") {
                states[platform.id] = AppState(
                    title: "Permissions Required",
                    subtitle: "Grant permission in System Settings > Privacy > Automation",
                    isPlaying: nil,
                    error: nil
                )
            } else if let lastLine = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !lastLine.isEmpty {
                let newState = platform.parseState(lastLine)
                states[platform.id] = newState
            }
        }
    }
    
    func setVolume(_ volume: Float) async {
        print("\n=== AppController: Setting Volume ===")
        print("Target volume: \(Int(volume * 100))%")
        guard isActive else {
            print("⚠️ Controller not active, skipping volume change")
            return
        }
        
        let script = "set volume output volume \(Int(volume * 100))"
        let result = await executeCommand(script, description: "System: set volume(\(Int(volume * 100)))")
        
        if case .success = result {
            print("✓ Volume set successfully")
        }
    }
    
    private func updateSystemVolume() async {
        print("\n=== AppController: Updating System Volume ===")
        guard isActive else {
            print("⚠️ Controller not active, skipping volume update")
            return
        }
        
        let script = """
        output volume of (get volume settings)
        """
        
        let result = await executeCommand(script, description: "System: get volume")
        
        if case .success(let output) = result,
           let volume = Float(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            currentVolume = volume / 100.0
            if let currentVolume = currentVolume {
                print("✓ Current volume: \(Int(currentVolume * 100))%")
            }
        } else {
            print("❌ Failed to get current volume")
        }
    }
    
    // Keep this simpler version for single commands (permissions checks, etc)
    private func executeCommand(_ command: String, description: String? = nil) async -> Result<String, Error> {
        print("\n=== AppController: Executing Command ===")
        if let description = description {
            print("Description: \(description)")
        }
        print("Command length: \(command.count) characters")
        
        guard isActive else {
            print("⚠️ Controller not active, skipping command")
            return .failure(SSHError.channelError("Controller not active"))
        }
        
        let wrappedCommand = """
        osascript << 'APPLESCRIPT'
        try
            \(command)
        on error errMsg
            return errMsg
        end try
        APPLESCRIPT
        """
        
        return await withCheckedContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(returning: .failure(SSHError.channelError("AppController was deallocated")))
                return
            }
            
            self.sshClient.executeCommandWithNewChannel(wrappedCommand, description: description) { result in
                switch result {
                case .success(let output):
                    print("✓ Command executed successfully")
                    if !output.isEmpty {
                        print("Output length: \(output.count) characters")
                    }
                    continuation.resume(returning: result)
                case .failure(let error):
                    print("❌ Command failed: \(error)")
                    
                    // Check if this is a connection loss
                    if let connectionManager = self.sshClient as? SSHConnectionManager,
                       connectionManager.isConnectionLossError(error) {
                        print("Connection appears to be lost")
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
