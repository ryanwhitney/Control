import SwiftUI
import Combine

struct ControlView: View, SSHConnectedView {
    let host: String
    let displayName: String
    let username: String
    let password: String
    
    private var enabledPlatforms: Set<String> {
        savedConnections.enabledPlatforms(host)
    }

    /// A connection set up before Keyboard existed: it has a saved app list and
    /// Keyboard isn't in it. An empty list doesn't count — the platforms then
    /// come from the defaults, which include Keyboard.
    private var isPreKeyboardConnection: Bool {
        !enabledPlatforms.isEmpty && !enabledPlatforms.contains("keyboard")
    }

    /// The Keyboard discovery hint for the More button and Manage Apps row. It
    /// points at Choose Apps, so opening Manage Apps or having seen that screen
    /// (where turning Keyboard off is a deliberate choice) retires it.
    private var showsKeyboardManageAppsHint: Bool {
        isPreKeyboardConnection
            && !preferences.hasSeenKeyboardHintManageApps
            && !preferences.hasSeenKeyboardHintChooseApps
    }

    /// Tracks Dynamic Type alongside the symbol it sits on.
    @ScaledMetric(relativeTo: .body) private var keyboardHintDotSize: CGFloat = 5

    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// So switching apps by the title's adjustable action keeps focus on the new
    /// title instead of resetting to the first element on the page.
    @AccessibilityFocusState private var focusedPlatformId: String?
    /// Superseded switches cancel it, so stale focus writes never fire.
    @State private var focusRestoreTask: Task<Void, Never>?
    @StateObject internal var connectionManager = SSHConnectionManager.shared
    @StateObject private var appController: AppController
    @StateObject private var preferences = UserPreferences.shared
    @EnvironmentObject private var savedConnections: SavedConnections
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Float = 0.5
    @State private var volumeInitialized: Bool = false
    @State private var _showingConnectionLostAlert = false
    @State private var showingCompatibilityNotice = false
    @State private var pendingVisibleCheck: Task<Void, Never>?
    @State private var showingThemeSettings: Bool = false
    @State private var showingDebugLogs: Bool = false
    @State private var selectedPlatformIndex: Int = 0
    @State private var _showingError = false
    @State private var _connectionError: (title: String, message: String)?
    @State private var showingSetupFlow = false
    /// So the status subtitle appears only on a *drop*, not during the first
    /// connect, which has its own loading treatment.
    @State private var hasEverConnected = false

    // MARK: - SSHConnectedView Protocol Properties
    var showingConnectionLostAlert: Binding<Bool> { $_showingConnectionLostAlert }
    var connectionError: Binding<(title: String, message: String)?> { $_connectionError }
    var showingError: Binding<Bool> { $_showingError }

    /// One alert off either flag — mid-session loss or failed reconnect.
    private var showingConnectionProblem: Binding<Bool> {
        Binding(
            get: { _showingConnectionLostAlert || _showingError },
            set: { newValue in
                if !newValue {
                    _showingConnectionLostAlert = false
                    _showingError = false
                }
            }
        )
    }

    // MARK: - SSH Connection Callbacks
    func onSSHConnected() {
        // The visible tab first, even a foreground-only one, so it shows status
        // right away. On Fast it's all that runs; other tabs load lazily.
        let visiblePlatformId = appController.platforms[safe: selectedPlatformIndex]?.id
        Task {
            appController.reset()
            await appController.performInitialRefresh(visiblePlatformId: visiblePlatformId)
            connectionManager.startHeartbeat()
        }
    }
    
    func onSSHConnectionFailed(_ error: Error) {
    }


    private var isPhoneLandscape: Bool {
        verticalSizeClass == .compact
    }
    
    init(host: String, displayName: String, username: String, password: String) {
        self.host = host
        self.displayName = displayName
        self.username = username
        self.password = password
        
        // Replaced in onAppear, once the platform list is known.
        _appController = StateObject(wrappedValue: AppController(sshClient: SSHConnectionManager.shared, platformRegistry: PlatformRegistry(platforms: [])))
    }
    
    private func updateAppControllerPlatforms() {
        var currentPlatforms = enabledPlatforms
        
        if currentPlatforms.isEmpty {
            let defaultRegistry = PlatformRegistry()
            currentPlatforms = defaultRegistry.enabledPlatforms
            viewLog("No saved platforms for host, using defaults: \(currentPlatforms)", view: "ControlView")
        }
        
        let newRegistry = PlatformRegistry()
        newRegistry.enabledPlatforms = currentPlatforms
        
        viewLog("Updating AppController with \(newRegistry.activePlatforms.count) active platforms: \(newRegistry.activePlatforms.map { $0.name })", view: "ControlView")
        
        appController.updatePlatformRegistry(newRegistry)
    }
    
    enum ConnectionStatus: Hashable {
        case reconnecting  // actively retrying — shows animated dots
        case notConnected  // retries exhausted, the failure alert is up
    }

    /// nil — the normal case — leaves the title centered with no subtitle.
    /// Suppressed until the first successful connect.
    private var connectionStatus: ConnectionStatus? {
        guard hasEverConnected else { return nil }
        // The alert only appears once auto-reconnect has given up.
        if _showingConnectionLostAlert || _showingError { return .notConnected }
        switch connectionManager.connectionState {
        case .connected:
            return nil
        case .connecting, .recovering, .failed, .disconnected:
            return .reconnecting
        }
    }

    @ViewBuilder
    private func statusLabel(for status: ConnectionStatus) -> some View {
        switch status {
        case .reconnecting:
            ReconnectingLabel()
        case .notConnected:
            Text("Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Connection status: Not connected")
        }
    }
    
    /// The paged platform controls. Split out of `body` purely so the type
    /// checker sees smaller expressions — a 370-line body took 1.2s to check,
    /// which Previews pays on every rebuild.
    private var platformPager: some View {
        TabView(selection: $selectedPlatformIndex) {
            ForEach(Array(appController.platforms.enumerated()), id: \.element.id) { index, platform in
                PlatformControl(
                    platform: platform,
                    state: Binding(
                        get: { appController.states[platform.id] ?? appController.lastKnownStates[platform.id] ?? AppState(title: "", subtitle: "") },
                        set: { appController.states[platform.id] = $0 }
                    ),
                    pageIndex: index,
                    pageCount: appController.platforms.count,
                    selectedIndex: selectedPlatformIndex,
                    selectedName: appController.platforms[safe: selectedPlatformIndex]?.name ?? "",
                    onSelectPage: { selectPlatform(at: $0) },
                    titleFocus: $focusedPlatformId
                )
                .padding(.top, isPhoneLandscape ? 0 : -54)

                .environmentObject(appController)
                .tag(index)
                .onAppear {
                    savedConnections.updateLastViewedPlatform(host, platform: platform.id)
                }
            }
        }
        .tabViewStyle(.page)
        .onChange(of: selectedPlatformIndex) { _, newValue in
            guard let platform = appController.platforms[safe: newValue] else { return }
            savedConnections.updateLastViewedPlatform(host, platform: platform.id)
            guard appController.hasCompletedInitialUpdate else { return }

            pendingVisibleCheck?.cancel()
            if platform.checksStatusOnlyWhenVisible {
                // Reading these foregrounds the Mac app, so a quick
                // swipe past must cancel rather than pop it forward.
                pendingVisibleCheck = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    await appController.updateState(for: platform)
                }
            } else {
                // Scrub-through repeats are capped by updateState's
                // own 2 s per-platform dedupe.
                Task { await appController.updateState(for: platform) }
            }
            // So nearby tabs fill first. No-op on Compatibility.
            appController.prefetchBackgroundTabs(around: platform.id)
        }
        // The dots ride a fixed inset above the pager's bottom edge,
        // so lowering them means extending that edge below its slot.
        // The pages carry matching clearance — see PlatformControl.
        .padding(.top, isPhoneLandscape ? 0 : -24)
    }

    private var volumeRow: some View {
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
                .accessibilityInputLabels(["Volume down", "Decrease volume", "Quieter"])
                .disabled(!volumeInitialized)
                WooglySlider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { newValue in
                            if volumeInitialized {
                                volume = Float(newValue)
                                // Coalescing lives in setVolume.
                                appController.setVolume(volume)
                            }
                        }
                    ),
                    in: 0...1,
                    step: 0.01,
                    onEditingChanged: { isEditing in
                        if !isEditing && volumeInitialized {
                            appController.setVolume(volume)
                        }
                    }
                )
                
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
                
                .accessibilityInputLabels(["Volume up", "Increase volume", "Louder"])
                .disabled(!volumeInitialized)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: 500, maxHeight: isPhoneLandscape ? 10 : nil)
    }

    /// Desaturates and blocks the controls while the connection is unhealthy.
    private var disconnectedOverlay: some View {
        Rectangle()
            .foregroundStyle(.black)
            .blendMode(.saturation)
            .opacity(connectionManager.connectionState == .connected ? 0 : 1)
            .animation(.spring(), value: connectionManager.connectionState)
            .allowsHitTesting(connectionManager.connectionState == .connected)
    }

    @ToolbarContentBuilder
    private var controlToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let status = connectionStatus {
                    statusLabel(for: status)
                        .id(status)
                        // From behind the title, which lifts to make room.
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: connectionStatus)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task {
                        await appController.updateAllStates(alwaysInclude: appController.platforms[safe: selectedPlatformIndex]?.id)
                    }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                Button {
                    showingThemeSettings = true
                } label: {
                    // Label, not HStack, so VoiceOver reads only the title
                    // and not the decorative symbol.
                    Label {
                        Text("Change Theme")
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(preferences.tintColorValue, .secondary)
                    }
                }
                Button {
                    preferences.markKeyboardHintManageAppsSeen()
                    showingSetupFlow = true
                } label: {
                    Label {
                        Text("Manage Apps")
                    } icon: {
                        // Same angled shape as the plain icon, so nothing
                        // shifts when the hint retires.
                        if showsKeyboardManageAppsHint {
                            Image("custom.rectangle.portrait.on.rectangle.portrait.angled.fill.badge")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(preferences.tintColorValue, .secondary)
                        } else {
                            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
                                .foregroundStyle(preferences.tintColorValue, .secondary)
                        }
                    }
                }
                .accessibilityHint(showsKeyboardManageAppsHint ? "New Keyboard controls" : "")
                if DebugLogger.shared.isLoggingEnabled {
                    Button {
                        showingDebugLogs = true
                    } label: {
                        Label {
                            Text("Debug Logs")
                        } icon: {
                            Image(systemName: "apple.terminal")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
            } label: {
                // An overlay, not a badged symbol: a badge grows the symbol's
                // box upward only, pushing the dots down by 27% of the point
                // size. An overlay adds no layout. Shares the Manage Apps flag.
                Image(systemName: "ellipsis")
                    .overlay(alignment: .topTrailing) {
                        if showsKeyboardManageAppsHint {
                            Circle()
                                .frame(width: keyboardHintDotSize, height: keyboardHintDotSize)
                                // Multiples of the dot, so placement scales with it.
                                .offset(x: keyboardHintDotSize * 0.63, y: -keyboardHintDotSize * 1.78)
                        }
                    }
                    .accessibilityLabel("More")
                    .accessibilityHint(showsKeyboardManageAppsHint ? "New Keyboard controls available" : "")
            }
        }
    }


    var body: some View {
        ZStack {
            VStack() {
                VStack {
                    // Landscape gives its centring whitespace to the pages,
                    // which set their own spacing (see PlatformControl).
                    if !isPhoneLandscape {
                        Spacer()
                    }
                    platformPager
                }
                // No spacer in portrait: the pager fills down to the volume row.
                volumeRow
                if !isPhoneLandscape {
                    Spacer(minLength: 20)
                }
            }
            .opacity(connectionManager.connectionState == .connected ? 1 : 0.3)
            .animation(.spring(), value: connectionManager.connectionState)

            disconnectedOverlay
        }
        // Landscape gives its vertical margins to the pages.
        .padding(.vertical, isPhoneLandscape ? 0 : 16)
        .padding(.bottom, isPhoneLandscape ? 8 : 0)
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .id(enabledPlatforms) // Force recreation when platforms change
        .toolbar { controlToolbar }
        .onAppear {
            viewLog("View appeared", view: "ControlView")
            viewLog("Enabled platforms: \(enabledPlatforms)", view: "ControlView")
            viewLog("Connection manager state: \(connectionManager.connectionState)", view: "ControlView")
            
            updateAppControllerPlatforms()
            setupSSHConnection()

            // Called when Fast connects but its stream never responds and the
            // manager falls back to Compatibility.
            let showNotice = $showingCompatibilityNotice
            connectionManager.setTransportFallbackHandler {
                showNotice.wrappedValue = true
                connectToSSH()
            }

            // Re-drives the full connect path after an involuntary drop.
            connectionManager.setReconnectHandler {
                connectToSSH()
            }

            if let lastPlatform = savedConnections.lastViewedPlatform(host),
               let index = appController.platforms.firstIndex(where: { $0.id == lastPlatform }) {
                viewLog("Restoring last viewed platform: \(lastPlatform) (index \(index))", view: "ControlView")
                selectedPlatformIndex = index
            } else {
                viewLog("No previous platform preference, using default index 0", view: "ControlView")
                // A stale index survives this view's @State when the platform
                // list shrinks, leaving the pager pointing past the end.
                selectedPlatformIndex = 0
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        .onDisappear {
            viewLog("View disappeared", view: "ControlView")
            focusRestoreTask?.cancel()
            Task { @MainActor in
                appController.cleanup()
                // They capture this Mac's credentials, and a later session's
                // drop must not re-drive a dismissed view's connect path.
                connectionManager.clearViewHandlers()
            }
        }
        .onReceive(appController.$currentVolume) { newVolume in
            if let newVolume = newVolume {
                viewLog("Volume updated to \(Int(newVolume * 100))%", view: "ControlView")
                volumeInitialized = true
                volume = newVolume
            } else {
                viewLog("Volume became nil - controls will be disabled", view: "ControlView")
            }
        }
        .onReceive(appController.$isActive) { isActive in
            viewLog("AppController active state changed to \(isActive)", view: "ControlView")
            if !isActive {
                viewLog("🚨 AppController became inactive - connection likely lost", view: "ControlView")
            }
        }
        .onReceive(connectionManager.$connectionState) { connectionState in
            viewLog("Connection state changed to \(connectionState)", view: "ControlView")
            switch connectionState {
            case .disconnected:
                viewLog("🚨Connection is disconnected", view: "ControlView")
            case .connecting:
                viewLog("⚯ Currently connecting...", view: "ControlView")
            case .recovering:
                viewLog("⚯ Recovering connection...", view: "ControlView")
            case .connected:
                viewLog("⚭ Connection established", view: "ControlView")
                hasEverConnected = true
            case .failed(let error):
                viewLog("❌ Connection failed: \(error)", view: "ControlView")
            }
        }
        // One modifier for both problems: two `.alert`s on one view conflict.
        // OK returns to the list, so a greyed-out ControlView is never a dead end.
        .alert(connectionError.wrappedValue?.title ?? "Connection Lost",
               isPresented: showingConnectionProblem) {
            Button("OK") { dismiss() }
        } message: {
            Text(connectionError.wrappedValue?.message
                 ?? SSHError.timeout.formatError(displayName: displayName).message)
        }
        .sheet(isPresented: $showingCompatibilityNotice) {
            CompatibilityFallbackNotice(displayName: displayName)
        }
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



    /// Switches the page and re-anchors VoiceOver focus on the incoming title
    /// once the pager settles. Only the latest switch's re-anchor survives, so
    /// rapid adjustments can't yank focus after the user has moved on.
    private func selectPlatform(at newIndex: Int) {
        guard let platform = appController.platforms[safe: newIndex] else { return }
        selectedPlatformIndex = newIndex
        focusRestoreTask?.cancel()
        focusRestoreTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            focusedPlatformId = platform.id
        }
    }

    private func adjustVolume(by amount: Int) {
        guard volumeInitialized else { 
            viewLog("⚠️ ControlView: Volume adjustment attempted before initialization", view: "ControlView")
            return 
        }
        
        let oldVolume = Int(volume * 100)
        let newVolume = min(max(Int(volume * 100) + amount, 0), 100)
        
        viewLog("Adjusting volume by \(amount)% (\(oldVolume)% -> \(newVolume)%)", view: "ControlView")
        
        volume = Float(newVolume) / 100.0
        appController.setVolume(volume)
    }
}

/// Live motion without a spinner. All three dots always occupy layout — hidden
/// ones are transparent — so the centered title never shifts.
private struct ReconnectingLabel: View {
    private let period = 0.35

    var body: some View {
        TimelineView(.periodic(from: .now, by: period)) { context in
            let visibleDots = Int(context.date.timeIntervalSinceReferenceDate / period) % 4
            HStack(spacing: 0) {
                Text("Reconnecting")
                ForEach(0..<3, id: \.self) { index in
                    Text(".").opacity(index < visibleDots ? 1 : 0)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reconnecting")
        .accessibilityAddTraits(.updatesFrequently)
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
