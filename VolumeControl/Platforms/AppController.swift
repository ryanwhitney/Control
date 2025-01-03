import SwiftUI

@MainActor
class AppController: ObservableObject {
    @Published var states: [String: AppState] = [:]
    @Published var currentVolume: Float = 0.5
    private let platformRegistry: PlatformRegistry
    private let sshClient: SSHClient
    private var commandQueue: AsyncStream<CommandOperation>
    private var commandContinuation: AsyncStream<CommandOperation>.Continuation?
    private var isShuttingDown = false
    
    private struct CommandOperation {
        let command: String
        let description: String?
        let continuation: CheckedContinuation<Result<String, Error>, Never>
    }
    
    var platforms: [any AppPlatform] {
        platformRegistry.activePlatforms
    }
    
    init(sshClient: SSHClient) {
        self.sshClient = sshClient
        self.platformRegistry = PlatformRegistry()
        
        // Initialize command queue
        var continuation: AsyncStream<CommandOperation>.Continuation!
        self.commandQueue = AsyncStream { cont in
            continuation = cont
            cont.onTermination = { @Sendable _ in
                print("Command queue terminated")
            }
        }
        self.commandContinuation = continuation
        
        // Initialize states for all platforms
        for platform in platformRegistry.platforms {
            states[platform.id] = AppState(
                title: "Loading...",
                subtitle: nil,
                isPlaying: nil,
                error: nil
            )
        }
        
        // Start command processor
        Task {
            await processCommands()
        }
        
        // Initial state fetch
        Task {
            await updateAllStates()
        }
    }
    
    private func processCommands() async {
        for await operation in commandQueue {
            guard !isShuttingDown else {
                operation.continuation.resume(returning: .failure(SSHError.channelNotConnected))
                continue
            }
            
            let wrappedCommand = """
            osascript << 'APPLESCRIPT'
            try
                \(operation.command)
            on error errMsg
                return errMsg
            end try
            APPLESCRIPT
            """
            
            let result = await withCheckedContinuation { continuation in
                sshClient.executeCommandWithNewChannel(wrappedCommand, description: operation.description) { result in
                    continuation.resume(returning: result)
                }
            }
            
            operation.continuation.resume(returning: result)
        }
    }
    
    private func enqueueCommand(_ command: String, description: String? = nil) async -> Result<String, Error> {
        guard !isShuttingDown else {
            return .failure(SSHError.channelNotConnected)
        }
        
        return await withCheckedContinuation { continuation in
            commandContinuation?.yield(CommandOperation(
                command: command,
                description: description,
                continuation: continuation
            ))
        }
    }
    
    // Updates all states - used by refresh button
    func updateAllStates() async {
        guard !isShuttingDown else { return }
        await updateVolume()
        for platform in platforms {
            await updateState(for: platform)
        }
    }
    
    // Updates state for a single platform - used when tab becomes visible
    func updateState(for platform: any AppPlatform) async {
        guard !isShuttingDown else { return }
        let script = platform.fetchState()
        let result = await enqueueCommand(script, description: "\(platform.name): fetch status")
        
        switch result {
        case .success(let output):
            let newState = platform.parseState(output)
            states[platform.id] = newState
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
        guard !isShuttingDown else { return }
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
        
        let result = await enqueueCommand(combinedScript, description: "\(platform.name): executeAction(.\(action))")
        
        if case .success(let output) = result {
            let lines = output.components(separatedBy: .newlines)
            if let lastLine = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
               !lastLine.isEmpty {
                let newState = platform.parseState(lastLine)
                states[platform.id] = newState
            }
        }
    }
    
    func setVolume(_ volume: Float) async {
        guard !isShuttingDown else { return }
        let script = "set volume output volume \(Int(volume * 100))"
        _ = await enqueueCommand(script, description: "System: set volume(\(Int(volume * 100)))")
    }
    
    private func updateVolume() async {
        guard !isShuttingDown else { return }
        let script = """
        get volume settings
        return output volume of result
        """
        let result = await enqueueCommand(script, description: "System: get volume")
        
        if case .success(let output) = result,
           let volumeLevel = Float(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            currentVolume = volumeLevel / 100.0
        }
    }
    
    func cleanup() {
        isShuttingDown = true
        commandContinuation?.finish()
        commandContinuation = nil
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
