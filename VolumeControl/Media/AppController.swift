import SwiftUI

@MainActor
class AppController: ObservableObject {
    @Published var states: [String: AppState] = [:]
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
                updateState(for: platform)
            }
        }
    }
    
    private func updateState(for platform: any AppPlatform) {
        print("updating state for \(platform.id)")
        let script = platform.fetchState()
        executeCommand(script) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    let newState = platform.parseState(output)
                    self?.states[platform.id] = newState
                case .failure(let error):
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
        let script = platform.executeAction(action)
        executeCommand(script) { _ in
            print("Action executed for \(platform.id)")
        }
        
        // Update state after a brief delay to let the app state settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateState(for: platform)
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
