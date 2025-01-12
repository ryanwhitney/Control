import SwiftUI
import Combine

struct ControlView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let enabledPlatforms: Set<String>
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var connectionManager = SSHConnectionManager()
    @StateObject private var appController: AppController
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Float?
    @State private var errorMessage: String?
    @State private var volumeChangeWorkItem: DispatchWorkItem?
    @State private var isReady: Bool = false
    @State private var shouldShowLoadingOverlay: Bool = false
    @State private var showingConnectionLostAlert = false
    
    init(host: String, displayName: String, username: String, password: String, enabledPlatforms: Set<String> = Set()) {
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
        
        // Initialize with a temporary client - it will be replaced when we connect
        _appController = StateObject(wrappedValue: AppController(sshClient: SSHClient(), platformRegistry: registry))
    }
    
    private var displayVolume: String {
        if let volume = volume {
            return "\(Int(volume * 100))%"
        } else {
            return "Loading..."
        }
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
                        
                        Text("Volume: \(displayVolume)")
                            .fontWeight(.bold)
                            .fontWidth(.expanded)
                            .accessibilityLabel("System Volume")
                            .accessibilityValue(displayVolume)
                        
                        if let currentVolume = volume {
                            Slider(value: Binding(
                                get: { currentVolume },
                                set: { newValue in
                                    volume = newValue
                                    debounceVolumeChange()
                                }
                            ), in: 0...1, step: 0.01)
                                .padding(.horizontal)
                                .accessibilityLabel("Volume Slider")
                                .accessibilityValue("\(Int(currentVolume * 100))%")
                                .accessibilityHint("Adjust to change system volume")
                        } else {
                            ProgressView()
                                .padding(.horizontal)
                                .accessibilityLabel("Loading volume")
                        }
                        
                        HStack(spacing: 16) {
                            ForEach([-5, -1, 1, 5], id: \.self) { adjustment in
                                Button {
                                    adjustVolume(by: adjustment)
                                } label: {
                                    Text(adjustment > 0 ? "+\(adjustment)" : "\(adjustment)")
                                }
                                .buttonStyle(CircularButtonStyle())
                                .disabled(volume == nil)
                                .accessibilityLabel("Adjust volume by \(adjustment)")
                                .accessibilityHint("Tap to \(adjustment > 0 ? "increase" : "decrease") volume by \(abs(adjustment))%")
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
            // Set up connection lost handler
            connectionManager.setConnectionLostHandler { @MainActor in
                showingConnectionLostAlert = true
            }
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
        .alert("Connection Lost", isPresented: $showingConnectionLostAlert) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("The connection to \(displayName) was lost. Please try connecting again.")
        }
    }
    
    private func connectToSSH() {
        print("\n=== ControlView: Initiating SSH Connection ===")
        Task {
            // Check if we need to reconnect
            if !connectionManager.shouldReconnect(host: host, username: username, password: password) {
                print("✓ Using existing connection")
                // Update app controller with current client
                appController.cleanup()
                appController.updateClient(connectionManager.client)
                await appController.updateAllStates()
                return
            }
            
            do {
                try await connectionManager.connect(host: host, username: username, password: password)
                print("✓ Connection established, updating app controller")
                
                // Update app controller with new client
                appController.cleanup()
                appController.updateClient(connectionManager.client)
                
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
        guard var currentVolume = volume else { return }
        let newVolume = min(max(Int(currentVolume * 100) + amount, 0), 100)
        currentVolume = Float(newVolume) / 100.0
        volume = currentVolume
        Task {
            await appController.setVolume(currentVolume)
        }
    }
    
    private func debounceVolumeChange() {
        guard let currentVolume = volume else { return }
        volumeChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task {
                await appController.setVolume(currentVolume)
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
                password: ""
            )
        }
    }
}
