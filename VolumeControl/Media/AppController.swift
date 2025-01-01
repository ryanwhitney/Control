import SwiftUI

@MainActor
class AppController: ObservableObject {
    @Published var states: [String: AppState] = [:]
    @Published var optimisticStates: [String: Bool] = [:]
    @Published var currentVolume: Float = 0.5
    private let platformRegistry: PlatformRegistry
    private let sshClient: SSHClient
    
    var platforms: [any AppPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClient) {
        self.sshClient = sshClient
        self.platformRegistry = PlatformRegistry()
        
        // Initialize states for all platforms
        for platform in platformRegistry.platforms {
            states[platform.id] = AppState(
                title: "Loading...",
                subtitle: nil,
                isPlaying: nil,
                error: nil
            )
        }
        
        // Initial state fetch
        updateAllStates()
    }
    
    func updateAllStates() {
        Task { @MainActor in
            await updateVolume()
            for platform in platforms {
                await updateState(for: platform)
            }
        }
    }
    
    private func updateState(for platform: any AppPlatform) async {
        let script = platform.fetchState()
        executeCommand(script) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let output):
                    let newState = platform.parseState(output)
                    self?.optimisticStates.removeValue(forKey: platform.id)
                    self?.states[platform.id] = newState
                case .failure(let error):
                    self?.optimisticStates.removeValue(forKey: platform.id)
                    self?.states[platform.id] = AppState(
                        title: "Error",
                        subtitle: nil,
                        isPlaying: nil,
                        error: error.localizedDescription
                    )
                }
            }
        }
    }
    
    func executeAction(platform: any AppPlatform, action: AppAction) {
        if case .playPauseToggle = action {
            let currentState = states[platform.id]?.isPlaying ?? false
            optimisticStates[platform.id] = !currentState
        }
        
        let script = platform.executeAction(action)
        executeCommand(script) { [weak self] _ in
            Task { @MainActor in
                // Wait briefly for the application to update its state
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.updateState(for: platform)
            }
        }
    }
    
    func setVolume(_ volume: Float) {
        let script = "set volume output volume \(Int(volume * 100))"
        executeCommand(script) { _ in }
    }
    
    private func executeCommand(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        let wrappedCommand = """
        osascript << 'APPLESCRIPT'
        \(command)
        APPLESCRIPT
        """
        sshClient.executeCommandWithNewChannel(wrappedCommand, completion: completion)
    }
    
    private func updateVolume() async {
        let script = """
        get volume settings
        return output volume of result
        """
        executeCommand(script) { [weak self] result in
            if case .success(let output) = result,
               let volumeLevel = Float(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                DispatchQueue.main.async {
                    self?.currentVolume = volumeLevel / 100.0
                }
            }
        }
    }
} 
