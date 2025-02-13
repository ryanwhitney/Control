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
    @StateObject private var savedConnections = SavedConnections()
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Float = 0.5  // Default value instead of optional
    @State private var volumeInitialized: Bool = false  // Track if we've received real volume
    @State private var errorMessage: String?
    @State private var volumeChangeWorkItem: DispatchWorkItem?
    @State private var isReady: Bool = false
    @State private var shouldShowLoadingOverlay: Bool = false
    @State private var showingConnectionLostAlert = false
    @State private var showingThemeSettings: Bool = false
    @State private var selectedPlatformIndex: Int = 0

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
        return "\(Int(volume * 100))%"
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let totalHeight = geometry.size.height
                let mediaHeight = totalHeight * 6 / 10
                VStack(spacing: 0) {
                    VStack {
                        TabView(selection: $selectedPlatformIndex) {
                            ForEach(Array(appController.platforms.enumerated()), id: \.element.id) { index, platform in
                                PlatformControl(
                                    platform: platform,
                                    state: Binding(
                                        get: { appController.states[platform.id] ?? appController.lastKnownStates[platform.id] ?? AppState(title: " ") },
                                        set: { appController.states[platform.id] = $0 }
                                    )
                                )
                                .environmentObject(appController)
                                .tag(index)
                            }
                        }
                        .tabViewStyle(.page)
                        .onChange(of: selectedPlatformIndex) { _, newValue in
                            if let platform = appController.platforms[safe: newValue] {
                                savedConnections.updateLastViewedPlatform(host, platform: platform.id)
                            }
                        }
                    }
                    .frame(height: mediaHeight)
                    
                    VStack(spacing: 20) {
                        Spacer()
                        
                        Text("Volume: \(displayVolume)")
                            .fontWeight(.bold)
                            .fontWidth(.expanded)
                            .accessibilityLabel("System Volume")
                            .accessibilityValue(displayVolume)
                        
                        Slider(value: Binding(
                            get: { volume },
                            set: { newValue in
                                if volumeInitialized {
                                    volume = newValue
                                    debounceVolumeChange()
                                }
                            }
                        ), in: 0...1, step: 0.01)
                            .padding(.horizontal)
                            .accessibilityLabel("Volume Slider")
                            .accessibilityValue("\(Int(volume * 100))%")
                            .accessibilityHint("Adjust to change system volume")
                            .disabled(!volumeInitialized)
                        
                        HStack(spacing: 16) {
                            ForEach([-5, -1, 1, 5], id: \.self) { adjustment in
                                Button {
                                    adjustVolume(by: adjustment)
                                } label: {
                                    Text(adjustment > 0 ? "+\(adjustment)" : "\(adjustment)")
                                }
                                .buttonStyle(CircularButtonStyle())
                                .disabled(!volumeInitialized)
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
        .tint(preferences.tintColorValue)
        .accentColor(preferences.tintColorValue)
        .navigationTitle(displayName)
        .toolbarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task {
                            await appController.updateAllStates()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showingThemeSettings = true
                    } label: {
                        HStack{
                            Text("Change Theme")
                            Image(systemName: "circle.fill")
                                .foregroundStyle(preferences.tintColorValue, .secondary)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .onAppear {
            // Set up connection lost handler
            connectionManager.setConnectionLostHandler { @MainActor in
                showingConnectionLostAlert = true
            }
            connectToSSH()
            
            // Set initial platform if one was previously selected
            if let lastPlatform = savedConnections.lastViewedPlatform(host),
               let index = appController.platforms.firstIndex(where: { $0.id == lastPlatform }) {
                selectedPlatformIndex = index
            }
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
            if let newVolume = newVolume {
                volumeInitialized = true
                volume = newVolume
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            print("\n=== ControlView: Will Resign Active ===")
            Task { @MainActor in
                appController.cleanup()
                connectionManager.disconnect()
            }
        }
        .alert("Connection Lost", isPresented: $showingConnectionLostAlert) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("The connection to \(displayName) was lost. Please try connecting again.")
        }
        .sheet(isPresented: $showingThemeSettings){
            ThemeSettingsSheet()
                .presentationDetents([.height(200)])
                .presentationDragIndicator(.visible)
        }
    }
    
    private func connectToSSH() {
        print("\n=== ControlView: Initiating SSH Connection ===")
        Task {
            // Check if we need to reconnect
            if !connectionManager.shouldReconnect(host: host, username: username, password: password) {
                print("✓ Using existing connection")
                // Update app controller with current client
                appController.updateClient(connectionManager.client)
                await appController.updateAllStates()
                return
            }
            
            do {
                try await connectionManager.connect(host: host, username: username, password: password)
                print("✓ Connection established, updating app controller")
                
                // Update app controller with new client
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
        guard volumeInitialized else { return }
        let newVolume = min(max(Int(volume * 100) + amount, 0), 100)
        volume = Float(newVolume) / 100.0
        Task {
            await appController.setVolume(volume)
        }
    }
    
    private func debounceVolumeChange() {
        guard volumeInitialized else { return }
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
                password: ""
            )
        }
    }
}

// Add a safe subscript extension for Array
extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < endIndex else { return nil }
        return self[index]
    }
}
