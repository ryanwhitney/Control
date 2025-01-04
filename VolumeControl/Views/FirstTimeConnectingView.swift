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
        ZStack {
            Form {
                Section {
                    VStack(alignment: .center){
                        Image(systemName: "macbook.and.iphone")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 60)
                            .foregroundStyle(.green, .quaternary)
                        
                        Text("Which apps would you like to control?")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("You can change these anytime.")
                            .foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                Section() {
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

            }
            VStack {
                Spacer()
                VStack(){
                    Button(action: {
                        onComplete(selectedPlatforms)
                    }) {
                        Text("Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity)
                    .disabled(selectedPlatforms.isEmpty)
                }.background(.black)
            }
        }
        .navigationTitle("First-Time Setup")
        .task {
            await checkAvailableApps()
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
    let client = SSHClient()
    client.connect(host: "rwhitney-mac.local", username: "ryan", password: "") { _ in }
    
    return NavigationStack {
        FirstTimeConnectingView(
            hostname: "rwhitney-mac.local",
            displayName: "Ryan's Mac",
            sshClient: client,
            onComplete: { _ in }
        )
    }
} 
