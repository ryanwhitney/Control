import SwiftUI
import Combine

struct ControlView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let enabledPlatforms: Set<String>
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var connectionManager = SSHConnectionManager.shared
    @StateObject private var appController: AppController
    @StateObject private var preferences = UserPreferences.shared
    @EnvironmentObject private var savedConnections: SavedConnections
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Float = 0.5
    @State private var volumeInitialized: Bool = false 
    @State private var errorMessage: String?
    @State private var volumeChangeWorkItem: DispatchWorkItem?
    @State private var isReady: Bool = false
    @State private var shouldShowLoadingOverlay: Bool = false
    @State private var showingConnectionLostAlert = false
    @State private var showingThemeSettings: Bool = false
    @State private var showingDebugLogs: Bool = false
    @State private var selectedPlatformIndex: Int = 0
    @State private var showingError = false
    @State private var connectionError: (title: String, message: String)?

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
        
        _appController = StateObject(wrappedValue: AppController(sshClient: SSHConnectionManager.shared.client, platformRegistry: registry))
    }
    
    private var displayVolume: String {
        return "\(Int(volume * 100))%"
    }
    
    var body: some View {
        ZStack {
            VStack() {
                VStack {
                    Spacer()
                    TabView(selection: $selectedPlatformIndex) {
                        ForEach(Array(appController.platforms.enumerated()), id: \.element.id) { index, platform in
                            PlatformControl(
                                platform: platform,
                                state: Binding(
                                    get: { appController.states[platform.id] ?? appController.lastKnownStates[platform.id] ?? AppState(title: "", subtitle: "") },
                                    set: { appController.states[platform.id] = $0 }
                                )
                            )
                            .environmentObject(appController)
                            .tag(index)
                            .onAppear {
                                savedConnections.updateLastViewedPlatform(host, platform: platform.id)
                            }
                        }
                    }
                    .tabViewStyle(.page)
                    .onChange(of: selectedPlatformIndex) { _, newValue in
                        if let platform = appController.platforms[safe: newValue] {
                            savedConnections.updateLastViewedPlatform(host, platform: platform.id)
                        }
                    }
                    Spacer()
                }
                Spacer(minLength: 40)
                VStack(alignment: .center) {
                    HStack(spacing: 0){
                        Button{
                            adjustVolume(by: -5)
                        } label: {
                            Label("Decrease volume 5%", systemImage: "speaker.minus.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(Color.accentColor)
                                .padding(10)
                                .padding(.top, 3)
                        }
                        .frame(width: 44, height: 44)
                        .disabled(!volumeInitialized)
                        WooglySlider(
                            value: Binding(
                                get: { Double(volume) },
                                set: { newValue in
                                    if volumeInitialized {
                                        volume = Float(newValue)
                                        debounceVolumeChange()
                                    }
                                }
                            ),
                            in: 0...1,
                            step: 0.01,
                            onEditingChanged: { _ in }
                        )
                        .accessibilityLabel("Volume Slider")
                        .accessibilityValue("system volume \(Int(volume * 100))%")
                        .disabled(!volumeInitialized)
                        Button{
                            adjustVolume(by: 5)
                        } label: {
                            Label("Increase volume 5%", systemImage: "speaker.plus.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(Color.accentColor)
                                .padding(10)
                                .padding(.top, 3)
                        }
                        .frame(width: 44, height: 44)
                        .disabled(!volumeInitialized)
                    }
                }
                .frame(maxWidth: 500)
                Spacer(minLength: 40)
            }
            .opacity(connectionManager.connectionState == .connected ? 1 : 0.3)
            .animation(.spring(), value: connectionManager.connectionState)

            //Overlay and Desaturate view when disconnected
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
                    Button {
                        showingDebugLogs = true
                    } label: {
                        HStack {
                            Text("Debug Logs")
                            if DebugLogger.shared.isLoggingEnabled {
                                Image(systemName: "apple.terminal")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .onAppear {
            // Set up connection lost handler
            connectionManager.setConnectionLostHandler { @MainActor in
                showingConnectionLostAlert = true
            }
            connectToSSH()
            // Set initial platform to open to
            if let lastPlatform = savedConnections.lastViewedPlatform(host),
               let index = appController.platforms.firstIndex(where: { $0.id == lastPlatform }) {
                selectedPlatformIndex = index
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            connectionManager.handleScenePhaseChange(from: oldPhase, to: newPhase)
            if newPhase == .active {
                connectToSSH()
            }
        }
        .onDisappear {
            print("\n=== ControlView: Disappearing ===")
            Task { @MainActor in
                appController.cleanup()
            }
        }
        .onReceive(appController.$currentVolume) { newVolume in
            if let newVolume = newVolume {
                volumeInitialized = true
                volume = newVolume
            }
        }
        .alert("Connection Lost", isPresented: $showingConnectionLostAlert) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text(SSHError.timeout.formatError(displayName: displayName).message)
        }
        .alert(connectionError?.title ?? "", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(connectionError?.message ?? "")
        }
        .sheet(isPresented: $showingThemeSettings){
            ThemePreferenceSheet()
                .presentationDetents([.height(200)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingDebugLogs) {
            DebugLogsView()
        }
    }

    private func connectToSSH() {
        connectionManager.handleConnection(
            host: host,
            username: username,
            password: password,
            onSuccess: { [weak appController] in
                await appController?.updateAllStates()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                    isReady = true
                }
            },
            onError: { error in
                if let sshError = error as? SSHError {
                    connectionError = sshError.formatError(displayName: displayName)
                } else {
                    connectionError = (
                        "Connection Error",
                        "An unexpected error occurred: \(error.localizedDescription)"
                    )
                }
                showingError = true
            }
        )
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
                host: ProcessInfo.processInfo.environment["ENV_HOST"] ?? "",
                displayName: ProcessInfo.processInfo.environment["ENV_NAME"] ?? "",
                username: ProcessInfo.processInfo.environment["ENV_USER"] ?? "",
                password: ProcessInfo.processInfo.environment["ENV_PASS"] ?? ""
            )
            .environmentObject(SavedConnections())
        }
    }
}

// safe subscript extension for Array
extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < endIndex else { return nil }
        return self[index]
    }
}
