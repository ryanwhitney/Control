import SwiftUI

struct FirstTimeConnectingView: View {
    let hostname: String
    let displayName: String
    @State private var selectedPlatforms: Set<String>
    @State private var isChecking = true
    @State private var checkResults: [String: Bool] = [:]
    let sshClient: SSHClientProtocol
    let onComplete: (Set<String>) -> Void
    
    init(hostname: String, displayName: String, sshClient: SSHClientProtocol, onComplete: @escaping (Set<String>) -> Void) {
        self.hostname = hostname
        self.displayName = displayName
        self.sshClient = sshClient
        self.onComplete = onComplete
        _selectedPlatforms = State(initialValue: Set())
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("Welcome to \(displayName)! Let's check which apps we can control on this computer.")
                        .foregroundStyle(.secondary)
                }
                
                Section("Available Apps") {
                    if isChecking {
                        HStack {
                            Text("Checking available apps...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        ForEach(PlatformRegistry.allPlatforms, id: \.id) { platform in
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { selectedPlatforms.contains(platform.id) },
                                    set: { isSelected in
                                        if isSelected {
                                            selectedPlatforms.insert(platform.id)
                                        } else {
                                            selectedPlatforms.remove(platform.id)
                                        }
                                    }
                                )) {
                                    VStack(alignment: .leading) {
                                        Text(platform.name)
                                        if let result = checkResults[platform.id] {
                                            Text(result ? "Available" : "Not installed")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(!checkResults[platform.id, default: false])
                            }
                        }
                    }
                }
                
                Section {
                    Button("Continue") {
                        onComplete(selectedPlatforms)
                    }
                    .disabled(selectedPlatforms.isEmpty)
                }
            }
            .navigationTitle("First-Time Setup")
            .task {
                await checkAvailableApps()
            }
        }
    }
    
    private func checkAvailableApps() async {
        isChecking = true
        checkResults.removeAll()
        
        // Check each platform in parallel
        await withTaskGroup(of: (String, Bool).self) { group in
            for platform in PlatformRegistry.allPlatforms {
                group.addTask {
                    let result = await checkPlatform(platform)
                    return (platform.id, result)
                }
            }
            
            // Collect results
            for await (platformId, isAvailable) in group {
                checkResults[platformId] = isAvailable
                if isAvailable {
                    selectedPlatforms.insert(platformId)
                }
            }
        }
        
        isChecking = false
    }
    
    private func checkPlatform(_ platform: any AppPlatform) async -> Bool {
        return await withCheckedContinuation { continuation in
            sshClient.executeCommandWithNewChannel(platform.isRunningScript(), description: "Check if \(platform.name) exists") { result in
                switch result {
                case .success(let output):
                    // If we can successfully check if it's running, the app exists
                    continuation.resume(returning: true)
                case .failure:
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        FirstTimeConnectingView(
            hostname: "ryans-mac.local",
            displayName: "Ryan's Mac",
            sshClient: MockSSHClient(),
            onComplete: { _ in }
        )
    }
}

// Mock SSH client for previews
private class MockSSHClient: SSHClientProtocol {
    func connect(host: String, username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    
    func disconnect() {}
    
    func executeCommandWithNewChannel(_ command: String, description: String?, completion: @escaping (Result<String, Error>) -> Void) {
        // Simulate checking app availability
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Randomly return true/false to show both states
            completion(.success(Bool.random() ? "true" : "false"))
        }
    }
} 