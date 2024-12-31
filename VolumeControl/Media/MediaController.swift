import SwiftUI

class MediaController: ObservableObject {
    @Published var states: [String: MediaState] = [:]
    @Published var optimisticStates: [String: Bool] = [:]
    private let platformRegistry: PlatformRegistry
    private let sshClient: SSHClient
    
    var platforms: [any MediaPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClient) {
        self.sshClient = sshClient
        self.platformRegistry = PlatformRegistry()
        
        // Initialize states for all platforms
        for platform in platformRegistry.platforms {
            states[platform.id] = MediaState(
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
            for platform in platforms {
                await updateState(for: platform)
            }
        }
    }
    
    private func updateState(for platform: any MediaPlatform) async {
        let script = platform.fetchState()
        executeCommand(script) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    self?.states[platform.id] = platform.parseState(output)
                case .failure(let error):
                    self?.states[platform.id] = MediaState(
                        title: "Error",
                        subtitle: nil,
                        isPlaying: nil,
                        error: error.localizedDescription
                    )
                }
            }
        }
    }
    
    func executeAction(platform: any MediaPlatform, action: MediaAction) {
        if case .playPauseToggle = action {
            let currentState = states[platform.id]?.isPlaying ?? false
            optimisticStates[platform.id] = !currentState
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.optimisticStates.removeValue(forKey: platform.id)
            }
        }
        
        let script = platform.executeAction(action)
        executeCommand(script) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateState(for: platform)
            }
        }
    }
    
    func setVolume(_ volume: Float) {
        let script = "set volume output volume \(Int(volume * 100))"
        executeCommand("osascript -e '\(script)'") { _ in }
    }
    
    private func executeCommand(_ command: String, completion: @escaping (Result<String, Error>) -> Void) {
        sshClient.executeCommandWithNewChannel("osascript -e '\(command)'", completion: completion)
    }
} 