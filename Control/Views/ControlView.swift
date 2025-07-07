import SwiftUI
import Combine

struct ControlView: View, SSHConnectedView {
    let host: String
    let displayName: String
    let username: String
    let password: String
    
    // Always get platforms from savedConnections (reactive)
    private var enabledPlatforms: Set<String> {
        savedConnections.enabledPlatforms(host)
    }
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @StateObject internal var connectionManager = SSHConnectionManager.shared
    @StateObject private var appController: AppController
    @StateObject private var preferences = UserPreferences.shared
    @EnvironmentObject private var savedConnections: SavedConnections
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Float = 0.5
    @State private var volumeInitialized: Bool = false 
    @State private var errorMessage: String?
    @State private var volumeChangeWorkItem: DispatchWorkItem? // unused but keep for other logic
    @State private var lastVolumeCommandDate: Date = .distantPast
    @State private var isReady: Bool = false
    @State private var shouldShowLoadingOverlay: Bool = false
    @State private var _showingConnectionLostAlert = false
    @State private var showingThemeSettings: Bool = false
    @State private var showingDebugLogs: Bool = false
    @State private var selectedPlatformIndex: Int = 0
    @State private var _showingError = false
    @State private var _connectionError: (title: String, message: String)?
    @State private var showingSetupFlow = false
    
    // MARK: - SSHConnectedView Protocol Properties
    var showingConnectionLostAlert: Binding<Bool> { $_showingConnectionLostAlert }
    var connectionError: Binding<(title: String, message: String)?> { $_connectionError }
    var showingError: Binding<Bool> { $_showingError }
    
    // MARK: - SSH Connection Callbacks
    func onSSHConnected() {
        Task {
            await appController.reset()
            await appController.updateAllStates()
            connectionManager.startHeartbeat()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            isReady = true
            viewLog("ControlView: Ready state activated", view: "ControlView")
        }
    }
    
    func onSSHConnectionFailed(_ error: Error) {
        // Error handling is done automatically by the mixin
    }


    private var isPhoneLandscape: Bool {
        verticalSizeClass == .compact
    }
    
    init(host: String, displayName: String, username: String, password: String) {
        self.host = host
        self.displayName = displayName
        self.username = username
        self.password = password
        
        // Create placeholder AppController - will be properly initialized in onAppear
        _appController = StateObject(wrappedValue: AppController(sshClient: SSHConnectionManager.shared, platformRegistry: PlatformRegistry(platforms: [])))
    }
    
    // Update AppController with current platforms
    private func updateAppControllerPlatforms() {
        var currentPlatforms = enabledPlatforms
        
        // If no platforms are saved for this host, use default enabled platforms
        if currentPlatforms.isEmpty {
            let defaultRegistry = PlatformRegistry()
            currentPlatforms = defaultRegistry.enabledPlatforms
            viewLog("ControlView: No saved platforms for host, using defaults: \(currentPlatforms)", view: "ControlView")
        }
        
        // Create new registry with all platforms, but update enabled platforms
        let newRegistry = PlatformRegistry()
        newRegistry.enabledPlatforms = currentPlatforms
        
        viewLog("ControlView: Updating AppController with \(newRegistry.activePlatforms.count) active platforms: \(newRegistry.activePlatforms.map { $0.name })", view: "ControlView")
        
        // Update the AppController's platform registry
        appController.updatePlatformRegistry(newRegistry)
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
                            
                            if appController.hasCompletedInitialUpdate {
                                Task {
                                    await appController.updateState(for: platform)
                                }
                            }
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
                                        let now = Date()
                                        if now.timeIntervalSince(lastVolumeCommandDate) > 0.4 {
                                            lastVolumeCommandDate = now
                                            Task { await appController.setVolume(volume) }
                                        }
                                    }
                                }
                            ),
                            in: 0...1,
                            step: 0.01,
                            onEditingChanged: { isEditing in
                                if !isEditing && volumeInitialized {
                                    // Send the final value immediately
                                    Task { await appController.setVolume(volume) }
                                }
                            }
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
                .padding()
                .frame(maxWidth: 500, maxHeight: isPhoneLandscape ? 10 : nil)
                if !isPhoneLandscape {
                    Spacer(minLength: 40)
                }
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
        .padding(.vertical)
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .id(enabledPlatforms) // Force recreation when platforms change
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(displayName)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            }
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
                        showingSetupFlow = true
                    } label: {
                        HStack{
                            Text("Manage Apps")
                            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
                                .foregroundStyle(preferences.tintColorValue, .secondary)
                        }
                    }
                    if DebugLogger.shared.isLoggingEnabled {
                        Button {
                            showingDebugLogs = true
                        } label: {
                            HStack {
                                Text("Debug Logs")
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
            viewLog("ControlView: View appeared", view: "ControlView")
            viewLog("Enabled platforms: \(enabledPlatforms)", view: "ControlView")
            viewLog("Connection manager state: \(connectionManager.connectionState)", view: "ControlView")
            
            // Update AppController with current platforms
            updateAppControllerPlatforms()
            
            // Set up SSH connection
            setupSSHConnection()
            
            // Set initial platform to open to
            if let lastPlatform = savedConnections.lastViewedPlatform(host),
               let index = appController.platforms.firstIndex(where: { $0.id == lastPlatform }) {
                viewLog("Restoring last viewed platform: \(lastPlatform) (index \(index))", view: "ControlView")
                selectedPlatformIndex = index
            } else {
                viewLog("No previous platform preference, using default index 0", view: "ControlView")
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        .onDisappear {
            viewLog("ControlView: View disappeared", view: "ControlView")
            Task { @MainActor in
                appController.cleanup()
            }
        }
        .onReceive(appController.$currentVolume) { newVolume in
            if let newVolume = newVolume {
                viewLog("ControlView: Volume updated to \(Int(newVolume * 100))%", view: "ControlView")
                volumeInitialized = true
                volume = newVolume
            } else {
                viewLog("ControlView: Volume became nil - controls will be disabled", view: "ControlView")
            }
        }
        .onReceive(appController.$isActive) { isActive in
            viewLog("ControlView: AppController active state changed to \(isActive)", view: "ControlView")
            if !isActive {
                viewLog("🚨 ControlView: AppController became inactive - connection likely lost", view: "ControlView")
            }
        }
        .onReceive(connectionManager.$connectionState) { connectionState in
            viewLog("ControlView: Connection state changed to \(connectionState)", view: "ControlView")
            switch connectionState {
            case .disconnected:
                viewLog("🚨 ControlView: Connection is disconnected", view: "ControlView")
            case .connecting:
                viewLog("ControlView: Currently connecting...", view: "ControlView")
            case .recovering:
                viewLog("ControlView: Recovering connection...", view: "ControlView")
            case .connected:
                viewLog("✓ ControlView: Connection established", view: "ControlView")
            case .failed(let error):
                viewLog("❌ ControlView: Connection failed: \(error)", view: "ControlView")
            }
        }
        .alert("Connection Lost", isPresented: showingConnectionLostAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text(SSHError.timeout.formatError(displayName: displayName).message)
        }
        .alert(isPresented: showingError) { connectionErrorAlert() }
        .sheet(isPresented: $showingThemeSettings){
            ThemePreferenceSheet()
                .presentationDetents([.height(200)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingDebugLogs) {
            DebugLogsView(isReadOnly: true)
        }
        .navigationDestination(isPresented: $showingSetupFlow) {
            SetupFlowView(
                host: host,
                displayName: displayName,
                username: username,
                password: password,
                isReconfiguration: true,
                onComplete: {
                    showingSetupFlow = false
                }
            )
            .environmentObject(savedConnections)
        }
    }



    private func adjustVolume(by amount: Int) {
        guard volumeInitialized else { 
            viewLog("⚠️ ControlView: Volume adjustment attempted before initialization", view: "ControlView")
            return 
        }
        
        let oldVolume = Int(volume * 100)
        let newVolume = min(max(Int(volume * 100) + amount, 0), 100)
        
        viewLog("ControlView: Adjusting volume by \(amount)% (\(oldVolume)% -> \(newVolume)%)", view: "ControlView")
        
        volume = Float(newVolume) / 100.0
        let now = Date()
        if now.timeIntervalSince(lastVolumeCommandDate) > 0.05 {
            lastVolumeCommandDate = now
            Task {
                await appController.setVolume(volume)
            }
        }
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
