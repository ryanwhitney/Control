import SwiftUI
import Combine

struct ControlView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    
    // Always get platforms from savedConnections (reactive)
    private var enabledPlatforms: Set<String> {
        savedConnections.enabledPlatforms(host)
    }
    
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
    @State private var showingSetupFlow = false


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
        let currentPlatforms = enabledPlatforms
        let filteredPlatforms = PlatformRegistry.allPlatforms.filter { platform in
            currentPlatforms.isEmpty || currentPlatforms.contains(platform.id)
        }
        
        viewLog("ControlView: Updating AppController with \(filteredPlatforms.count) platforms: \(filteredPlatforms.map { $0.name })", view: "ControlView")
        
        // Create new registry with current platforms
        let newRegistry = PlatformRegistry(platforms: filteredPlatforms)
        
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
        .id(enabledPlatforms) // Force recreation when platforms change
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
                        showingSetupFlow = true
                    } label: {
                        HStack{
                            Text("Manage Apps")
                            Image(systemName: "square.fill.on.square.fill")
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
            
            // Show connection metadata without exposing sensitive info
            let isLocal = host.contains(".local")
            let connectionType = isLocal ? "SSH over Bonjour (.local)" : "SSH over TCP/IP"
            let hostRedacted = String(host.prefix(3)) + "***"
            
            viewLog("Target: \(hostRedacted)", view: "ControlView")
            viewLog("Protocol: \(connectionType)", view: "ControlView")
            viewLog("Display name: \(String(displayName.prefix(3)))***", view: "ControlView")
            viewLog("Enabled platforms: \(enabledPlatforms)", view: "ControlView")
            viewLog("Connection manager state: \(connectionManager.connectionState)", view: "ControlView")
            
            // Update AppController with current platforms
            updateAppControllerPlatforms()
            
            // Set up connection lost handler
            connectionManager.setConnectionLostHandler { @MainActor in
                viewLog("⚠️ ControlView: Connection lost handler triggered", view: "ControlView")
                showingConnectionLostAlert = true
            }
            connectToSSH()
            
            // Set initial platform to open to
            if let lastPlatform = savedConnections.lastViewedPlatform(host),
               let index = appController.platforms.firstIndex(where: { $0.id == lastPlatform }) {
                viewLog("Restoring last viewed platform: \(lastPlatform) (index \(index))", view: "ControlView")
                selectedPlatformIndex = index
            } else {
                viewLog("No previous platform preference, using default index 0", view: "ControlView")
            }
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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            viewLog("ControlView: Scene phase changed from \(oldPhase) to \(newPhase)", view: "ControlView")
            connectionManager.handleScenePhaseChange(from: oldPhase, to: newPhase)
            if newPhase == .active {
                viewLog("Scene became active - checking connection health", view: "ControlView")
                // First check if connection is healthy, then reconnect if needed
                Task {
                    if connectionManager.connectionState == .connected {
                        viewLog("Connection appears active, verifying health...", view: "ControlView")
                        do {
                            try await connectionManager.verifyConnectionHealth()
                            viewLog("✓ Connection health verified", view: "ControlView")
                            // Connection is healthy, update app states
                            await appController.updateAllStates()
                        } catch {
                            viewLog("❌ Connection health check failed: \(error)", view: "ControlView")
                            // Connection is dead, reconnect
                            connectToSSH()
                        }
                    } else {
                        viewLog("Connection not active, reconnecting...", view: "ControlView")
                        connectToSSH()
                    }
                }
            }
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
            case .connected:
                viewLog("✓ ControlView: Connection established", view: "ControlView")
            case .failed(let error):
                viewLog("❌ ControlView: Connection failed: \(error)", view: "ControlView")
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
            DebugLogsView(isReadOnly: true)
        }
    }

    private func connectToSSH() {
        viewLog("ControlView: Starting SSH connection", view: "ControlView")
        viewLog("Current connection state: \(connectionManager.connectionState)", view: "ControlView")
        
        connectionManager.handleConnection(
            host: host,
            username: username,
            password: password,
            onSuccess: { [weak appController] in
                viewLog("✓ ControlView: SSH connection successful", view: "ControlView")
                await appController?.updateAllStates()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                    isReady = true
                    viewLog("ControlView: Ready state activated", view: "ControlView")
                }
            },
            onError: { error in
                viewLog("❌ ControlView: SSH connection failed", view: "ControlView")
                viewLog("Error: \(error)", view: "ControlView")
                
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
        guard volumeInitialized else { 
            viewLog("⚠️ ControlView: Volume adjustment attempted before initialization", view: "ControlView")
            return 
        }
        
        let oldVolume = Int(volume * 100)
        let newVolume = min(max(Int(volume * 100) + amount, 0), 100)
        
        viewLog("ControlView: Adjusting volume by \(amount)% (\(oldVolume)% -> \(newVolume)%)", view: "ControlView")
        
        volume = Float(newVolume) / 100.0
        Task {
            await appController.setVolume(volume)
        }
    }
    
    private func debounceVolumeChange() {
        guard volumeInitialized else { 
            viewLog("⚠️ ControlView: Volume change attempted before initialization", view: "ControlView")
            return 
        }
        
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
