import SwiftUI

@MainActor
class AppController: ObservableObject {
    private var sshClient: SSHClientProtocol
    private let platformRegistry: PlatformRegistry
    private var isUpdating = false
    private var isActive = true
    
    @Published var states: [String: AppState] = [:]
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
            states[platform.id] = AppState(title: "Loading...")
        }
    }
    
    func reset() {
        print("\n=== AppController: Resetting ===")
        isActive = true
        isUpdating = false
        states = [:]
        currentVolume = nil
    }
    
    func cleanup() {
        print("\n=== AppController: Cleaning up ===")
        isActive = false
    }
    
    func updateAllStates() async {
        print("\n=== AppController: Updating All States ===")
        guard isActive else {
            print("⚠️ Controller not active, skipping update")
            return
        }
        
        // Update system volume
        await updateSystemVolume()
        
        // First check which apps are running
        for platform in platforms {
            print("\nChecking platform: \(platform.name)")
            let isRunning = await checkIfRunning(platform)
            if isRunning {
                print("✓ \(platform.name) is running, updating state")
                await updateState(for: platform)
            } else {
                print("⚠️ \(platform.name) is not running")
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
                    let errorString = error.localizedDescription.lowercased()
                    if errorString.contains("eof") || 
                       errorString.contains("connection reset") ||
                       errorString.contains("broken pipe") ||
                       errorString.contains("connection closed") {
                        print("Connection appears to be lost")
                        if let connectionManager = self.sshClient as? SSHConnectionManager {
                            connectionManager.handleConnectionLost()
                        }
                    }
                    continuation.resume(returning: result)
                }
            }
        }
    }
    
    func updateClient(_ newClient: SSHClientProtocol) {
        print("\n=== AppController: Updating SSH Client ===")
        cleanup()
        sshClient = newClient
        reset()
    }
} 
