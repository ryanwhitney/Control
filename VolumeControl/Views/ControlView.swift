import SwiftUI
import Combine

struct ControlView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let enabledPlatforms: Set<String>
    
    @StateObject private var connectionManager = SSHConnectionManager()
    @StateObject private var appController: AppController
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Float = 0.5
    @State private var errorMessage: String?
    @State private var volumeChangeWorkItem: DispatchWorkItem?
    @State private var isReady: Bool = false
    @State private var shouldShowLoadingOverlay: Bool = false
    
    init(host: String, displayName: String, username: String, password: String, sshClient: SSHClientProtocol, enabledPlatforms: Set<String> = Set()) {
        self.host = host
        self.displayName = displayName
        self.username = username
        self.password = password
        self.enabledPlatforms = enabledPlatforms
        
        // Filter platforms based on enabled set
        let filteredPlatforms = PlatformRegistry.allPlatforms.filter { platform in
            enabledPlatforms.isEmpty || enabledPlatforms.contains(platform.id)
        }
        let registry = PlatformRegistry(platforms: filteredPlatforms)
        
        // Initialize with the connection manager's client
        _appController = StateObject(wrappedValue: AppController(sshClient: sshClient, platformRegistry: registry))
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let totalHeight = geometry.size.height
                let mediaHeight = totalHeight * 6 / 10
                VStack(spacing: 0) {
                    VStack {
                        TabView {
                            ForEach(appController.platforms, id: \.id) { platform in
                                PlatformControl(
                                    platform: platform,
                                    state: Binding(
                                        get: { appController.states[platform.id] ?? AppState(title: "Error") },
                                        set: { appController.states[platform.id] = $0 }
                                    )
                                )
                                .environmentObject(appController)
                            }
                        }
                        .tabViewStyle(.page)
                    }
                    .frame(height: mediaHeight)
                    
                    VStack(spacing: 20) {
                        Spacer()
                        
                        Text("Volume: \(Int(volume * 100))%")
                            .fontWeight(.bold)
                            .fontWidth(.expanded)
                        
                        Slider(value: $volume, in: 0...1, step: 0.01)
                            .padding(.horizontal)
                            .onChange(of: volume) { oldValue, newValue in
                                debounceVolumeChange()
                            }
                        HStack(spacing: 16) {
                            ForEach([-5, -1, 1, 5], id: \.self) { adjustment in
                                Button {
                                    adjustVolume(by: adjustment)
                                } label: {
                                    Text(adjustment > 0 ? "+\(adjustment)" : "\(adjustment)")
                                }
                                .buttonStyle(CircularButtonStyle())
                            }
                        }
                        Spacer()
                    }
                    
                }
                .opacity(connectionManager.connectionState == .connected ? 1 : 0.3)
                .animation(.spring(), value: connectionManager.connectionState)
            }
            Rectangle()
                .foregroundStyle(.black)
                .blendMode(.saturation)
                .opacity(connectionManager.connectionState == .connected ? 0 : 1)
                .animation(.spring(), value: connectionManager.connectionState)
                .allowsHitTesting(connectionManager.connectionState == .connected)
        }
        .padding()
        .navigationTitle(displayName)
        .toolbarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await appController.updateAllStates()
                    }
                }
            }
        }
        .onAppear {
            connectToSSH()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            print("\n=== ControlView: Scene Phase Change ===")
            print("Old phase: \(oldPhase)")
            print("New phase: \(newPhase)")
            
            if newPhase == .active {
                print("Scene became active - connecting")
                connectToSSH()
            } else if newPhase == .background {
                print("Scene entering background - cleaning up")
                Task { @MainActor in
                    appController.cleanup()
                    connectionManager.disconnect()
                }
            }
        }
        .onDisappear {
            print("\n=== ControlView: Disappearing ===")
            Task { @MainActor in
                appController.cleanup()
                connectionManager.disconnect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            print("\n=== ControlView: Will Enter Foreground ===")
            connectToSSH()
        }
        .onReceive(appController.$currentVolume) { newVolume in
            self.volume = newVolume
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            print("\n=== ControlView: Will Resign Active ===")
            Task { @MainActor in
                appController.cleanup()
                connectionManager.disconnect()
            }
        }
        .tint(preferences.tintColorValue)
        .accentColor(preferences.tintColorValue)
    }
    
    private func connectToSSH() {
        print("\n=== ControlView: Initiating SSH Connection ===")
        Task {
            do {
                try await connectionManager.connect(host: host, username: username, password: password)
                print("✓ Connection established, updating app controller")
                
                // Update app controller with new client
                appController.cleanup()
                appController.reset()
                
                // Update states
                await appController.updateAllStates()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                    isReady = true
                }
            } catch {
                print("❌ Connection failed in ControlView: \(error)")
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func adjustVolume(by amount: Int) {
        let newVolume = min(max(Int(volume * 100) + amount, 0), 100)
        volume = Float(newVolume) / 100.0
        Task {
            await appController.setVolume(volume)
        }
    }
    
    private func debounceVolumeChange() {
        volumeChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task {
                await appController.setVolume(volume)
            }
        }
        volumeChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
}

struct ControlView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ControlView(
                host: "rwhitney-mac.local",
                displayName: "Ryan's Mac",
                username: "ryan",
                password: "",
                sshClient: SSHClient()
            )
        }
    }
}
