import SwiftUI

@MainActor
class AppController: ObservableObject {
    private let sshClient: SSHClientProtocol
    private let platformRegistry: PlatformRegistry
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
    }
    
    func reset() {
        isActive = true
        isUpdating = false
    }
    
    func cleanup() {
        isActive = false
        isUpdating = false
    }
    
    func updateAllStates() async {
        guard isActive else { return }
        
        // Update system volume
        await updateSystemVolume()
        
        // First check which apps are running
        for platform in platforms {
            let isRunning = await checkIfRunning(platform)
            if isRunning {
                await updateState(for: platform)
            } else {
                states[platform.id] = AppState(
                    title: "Not Running",
                    subtitle: nil,
                    isPlaying: nil,
                    error: nil
                )
            }
        }
    }
    
    func updateState(for platform: any AppPlatform) async {
        guard isActive else { return }
        
        let isRunning = await checkIfRunning(platform)
        guard isRunning else {
            states[platform.id] = AppState(
                title: "Not Running",
                subtitle: nil,
                isPlaying: nil,
                error: nil
            )
            return
        }
        
        let result = await executeCommand(platform.fetchState(), description: "\(platform.name): fetch status")
        
        switch result {
        case .success(let output):
            if output.contains("Not authorized to send Apple events") {
                states[platform.id] = AppState(
                    title: "Permissions Required",
                    subtitle: "Grant permission in System Settings > Privacy > Automation",
                    isPlaying: nil,
                    error: nil
                )
            } else {
                states[platform.id] = platform.parseState(output)
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
    
    private func checkIfRunning(_ platform: any AppPlatform) async -> Bool {
        guard isActive else { return false }
        
        let result = await executeCommand(platform.isRunningScript(), description: "\(platform.name): check if running")
        
        switch result {
        case .success(let output):
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        case .failure:
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
        guard isActive else { return }
        let script = "set volume output volume \(Int(volume * 100))"
        _ = await executeCommand(script, description: "System: set volume(\(Int(volume * 100)))")
    }
    
    private func updateSystemVolume() async {
        guard isActive else { return }
        
        let script = """
        output volume of (get volume settings)
        """
        
        let result = await executeCommand(script, description: "System: get volume")
        
        if case .success(let output) = result,
           let volume = Float(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            currentVolume = volume / 100.0
        }
    }
    
    // Keep this simpler version for single commands (permissions checks, etc)
    private func executeCommand(_ command: String, description: String? = nil) async -> Result<String, Error> {
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
} 
