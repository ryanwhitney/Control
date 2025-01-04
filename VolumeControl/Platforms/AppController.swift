import SwiftUI

@MainActor
class AppController: ObservableObject {
    private let sshClient: SSHClientProtocol
    private let platformRegistry: PlatformRegistry
    private var stateUpdateTimer: Timer?
    private var isUpdating = false
    private var isActive = true
    
    @Published var states: [String: AppState] = [:]
    @Published var currentVolume: Float = 0.5
    
    var platforms: [any AppPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClientProtocol, platformRegistry: PlatformRegistry) {
        self.sshClient = sshClient
        self.platformRegistry = platformRegistry
        
        // Initialize states
        for platform in platformRegistry.platforms {
            states[platform.id] = AppState(title: "Loading...")
        }
        
        // Start periodic updates
        startPeriodicUpdates()
    }
    
    private func startPeriodicUpdates() {
        isActive = true
        // Initial update
        Task {
            await updateAllStates()
        }
        
        // Set up timer for periodic updates
        stateUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.updateAllStates()
            }
        }
    }
    
    private func executeCommand(_ command: String, description: String? = nil) async -> Result<String, Error> {
        guard isActive else {
            return .failure(SSHError.channelNotConnected)
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
        
        return await withCheckedContinuation { continuation in
            sshClient.executeCommandWithNewChannel(wrappedCommand, description: description) { result in
                continuation.resume(returning: result)
            }
        }
    }
    
    // Updates all states - used by refresh button
    func updateAllStates() async {
        guard isActive else { return }
        await updateVolume()
        for platform in platforms {
            await updateState(for: platform)
        }
    }
    
    // Updates state for a single platform - used when tab becomes visible
    func updateState(for platform: any AppPlatform) async {
        guard isActive else { return }
        
        // First check if the app is running
        let isRunningScript = platform.isRunningScript()
        let isRunningResult = await executeCommand(isRunningScript, description: "\(platform.name): check if running")
        
        switch isRunningResult {
        case .success(let output):
            let isRunning = output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            if isRunning {
                // App is running, fetch its state
                let script = platform.fetchState()
                let result = await executeCommand(script, description: "\(platform.name): fetch status")
                
                switch result {
                case .success(let output):
                    // Check if the output contains an authorization error
                    if output.contains("Not authorized to send Apple events") {
                        states[platform.id] = AppState(
                            title: "Permissions Required",
                            subtitle: "Grant permission in System Settings > Privacy > Automation",
                            isPlaying: nil,
                            error: nil
                        )
                    } else {
                        let newState = platform.parseState(output)
                        states[platform.id] = newState
                    }
                case .failure(let error):
                    states[platform.id] = AppState(
                        title: "Error",
                        subtitle: nil,
                        isPlaying: nil,
                        error: error.localizedDescription
                    )
                }
            } else {
                // App is not running
                states[platform.id] = AppState(
                    title: "Not Open",
                    subtitle: "\(platform.name) is not running",
                    isPlaying: nil,
                    error: nil
                )
            }
        case .failure(let error):
            states[platform.id] = AppState(
                title: "Error",
                subtitle: nil,
                isPlaying: nil,
                error: error.localizedDescription
            )
        }
    }
    
    func executeAction(platform: any AppPlatform, action: AppAction) async {
        guard isActive else { return }
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
        guard isActive else { return }
        let script = "set volume output volume \(Int(volume * 100))"
        _ = await executeCommand(script, description: "System: set volume(\(Int(volume * 100)))")
    }
    
    private func updateVolume() async {
        guard isActive else { return }
        let script = """
        get volume settings
        return output volume of result
        """
        let result = await executeCommand(script, description: "System: get volume")
        
        if case .success(let output) = result,
           let volumeLevel = Float(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            currentVolume = volumeLevel / 100.0
        }
    }
    
    func cleanup() {
        isActive = false
        stateUpdateTimer?.invalidate()
        stateUpdateTimer = nil
    }
    
    func reset() {
        cleanup()
        startPeriodicUpdates()
    }
    
    nonisolated func cleanupSync() {
        Task { @MainActor in
            cleanup()
        }
    }
    
    deinit {
        cleanupSync()
    }
} 
