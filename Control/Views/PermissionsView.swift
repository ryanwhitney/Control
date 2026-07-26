import SwiftUI
import MultiBlur

enum PlatformPermissionState: Equatable {
    case initial
    case checking
    case granted
    /// `nil` when the check never got an answer, so there are no instructions to
    /// offer — only a named grant has a fix the sheet can describe.
    case failed(PermissionKind?)

    var spokenStatus: String {
        switch self {
        case .initial: return "not checked yet"
        case .checking: return "checking"
        case .granted: return "permission granted"
        case .failed(.automation): return "app control permission needed"
        case .failed(.accessibility): return "key press permission needed"
        case .failed(nil): return "permission check timed out"
        }
    }
}

struct PermissionsView: View, SSHConnectedView {
    let host: String
    let displayName: String
    let username: String
    let password: String
    /// Only the apps being granted in this pass, which may be a subset of the
    /// connection's full list — callers don't re-check what's already set up.
    let enabledPlatforms: Set<String>
    let onComplete: () -> Void

    @StateObject internal var connectionManager = SSHConnectionManager.shared
    @State private var permissionStates: [String: PlatformPermissionState] = [:]
    @State private var isCheckSweepRunning = false
    @State private var permissionsGranted: Bool = false
    @State private var showSuccess: Bool = false
    @State private var headerHeight: CGFloat = 0
    @State private var bottomPanelHeight: CGFloat = 0
    @State private var showAppList: Bool = false
    @State private var _showingConnectionLostAlert = false
    @State private var _showingError = false
    @State private var _connectionError: (title: String, message: String)?
    @State private var showingPermissionsNameExplanation = false
    /// Non-nil once the success choreography has started; it runs exactly once.
    @State private var successSequenceTask: Task<Void, Never>?
    /// The failed platform whose instructions are open, so dismissing can
    /// re-check just that one.
    @State private var helpFor: PermissionHelpRequest?

    struct PermissionHelpRequest: Identifiable {
        let platformId: String
        let kind: PermissionKind
        var id: String { platformId }
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - SSHConnectedView Protocol Properties
    var showingConnectionLostAlert: Binding<Bool> { $_showingConnectionLostAlert }
    var connectionError: Binding<(title: String, message: String)?> { $_connectionError }
    var showingError: Binding<Bool> { $_showingError }
    
    // MARK: - SSH Connection Callbacks
    func onSSHConnected() {
    }
    
    func onSSHConnectionFailed(_ error: Error) {
    }

    var body: some View {
        ZStack {
            successView
                .opacity(showSuccess ? 1 : 0)
                .accessibilityHidden(!showSuccess)

            mainPermissionsView
                .opacity(permissionsGranted ? 0 : 1)
                .accessibilityHidden(permissionsGranted)
        }
        .onAppear {
            for platformId in enabledPlatforms {
                if permissionStates[platformId] == nil {
                    permissionStates[platformId] = .initial
                }
            }

            setupSSHConnection()

            if allPermissionsGranted {
                permissionsGranted = true
                // `onChange` can't fire for a value that arrived already true.
                startSuccessSequence()
            }
        }
        .onDisappear {
            // No further beats, and no `onComplete()` from a screen that's gone.
            successSequenceTask?.cancel()
        }
        .onChange(of: scenePhase, handleScenePhaseChange)
        .alert("Connection Lost", isPresented: showingConnectionLostAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text(SSHError.timeout.formatError(displayName: displayName).message)
        }
        .alert(isPresented: showingError) { connectionErrorAlert() }
        .onChange(of: allPermissionsGranted) {
            guard allPermissionsGranted else { return }
            // Otherwise conveyed by a visual crossfade only.
            AccessibilityNotification.Announcement("All permissions granted. You're all set.").post()
            startSuccessSequence()
        }
        .onChange(of: showingPermissionsNameExplanation) { _, isOpen in
            if !isOpen {
                startSuccessSequence()
            }
        }
        .sheet(item: $helpFor) { help in
            PermissionsHelpSheet(kind: help.kind)
                .onDisappear {
                    // Just this one: a full sweep re-activates every app on the
                    // Mac, too intrusive to do on the chance they fixed it.
                    Task { await checkPermission(for: help.platformId) }
                }
        }
    }

    /// The granted → success → onComplete choreography as one awaitable sequence,
    /// so it can hold between beats while the explanation sheet is open.
    private func startSuccessSequence() {
        guard allPermissionsGranted, successSequenceTask == nil else { return }
        successSequenceTask = Task { @MainActor in
            // Cleared however this ends: leaving it set after a cancellation
            // would make the guard above permanent, stranding the user on a
            // screen whose only exit is `onComplete()`.
            defer { successSequenceTask = nil }
            // A beat throws only on cancellation: `onComplete()` drives
            // navigation and must not fire from a screen the user has left.
            do {
                try await paceSuccessBeat(.seconds(1))
                withAnimation(.spring()) {
                    permissionsGranted = true
                }
                try await paceSuccessBeat(.milliseconds(500))
                withAnimation(.spring()) {
                    showSuccess = true
                }
                try await paceSuccessBeat(.seconds(2))
                withAnimation(.spring()) {
                    showSuccess = false
                }
                try await paceSuccessBeat(.milliseconds(500))
                withAnimation(.spring()) {
                    onComplete()
                }
            } catch {}
        }
    }

    /// The interval, then a hold while the explanation sheet is open so no step
    /// fires underneath it. Throws on cancellation — the hold has no other exit.
    @MainActor
    private func paceSuccessBeat(_ interval: Duration) async throws {
        try await Task.sleep(for: interval)
        while showingPermissionsNameExplanation {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private var successView: some View {
        VStack {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .frame(width: 50, height: 50)
                .foregroundStyle(.tint)
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            Text("You're all set")
                .font(.title2)
                .bold()
        }
        .accessibilityElement(children: .combine)
        .padding()
    }

    private var mainPermissionsView: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .top){
                ScrollView(showsIndicators: false) {
                    HStack{EmptyView()}.frame(height: headerHeight)
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(PlatformRegistry.allPlatforms.filter { enabledPlatforms.contains($0.id) }, id: \.id) { platform in
                            let fixableKind = fixableKind(for: platform.id)
                            HStack {
                                Text(platform.name)
                                Spacer()
                                permissionStatusIcon(for: platform.id)
                                if fixableKind != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding()
                            .background(.ultraThinMaterial.opacity(0.5))
                            .cornerRadius(12)
                            .opacity(permissionStates[platform.id] != .initial ? 1 : 0.5)
                            .animation(.spring(), value: permissionStates[platform.id])
                            // The whole row, not the chevron: it's one
                            // accessibility element, and a chevron-sized target
                            // would be a sliver.
                            .contentShape(.rect(cornerRadius: 12))
                            .onTapGesture {
                                if let fixableKind {
                                    helpFor = PermissionHelpRequest(platformId: platform.id, kind: fixableKind)
                                }
                            }
                            // So an unchecked row reads "not checked yet" rather
                            // than a bare app name.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(platform.name)
                            .accessibilityValue(state(of: platform.id).spokenStatus)
                            .accessibilityAddTraits(fixableKind != nil ? .isButton : [])
                            .accessibilityHint(fixableKind != nil ? "Shows how to fix this on your Mac" : "")
                        }
                    }
                    .opacity(showAppList ? 1 : 0)
                    .onChange(of: headerHeight){
                        if headerHeight > 0 {
                            withAnimation(.spring()) {
                                showAppList = true
                            }

                        }
                    }
                    .padding()
                    .padding(.bottom, bottomPanelHeight + 12)
                }
                .mask(
                    LinearGradient(colors:[.clear, .black, .black, .black, .black, .black], startPoint: .top, endPoint: .bottom)
                )
                .background(Color(.systemBackground))
                .cornerRadius(12)
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.and.cursorarrow")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 50, height: 40)
                        .padding(0)
                        .foregroundStyle(.primary, .tint)
                        .padding(.bottom, -20)
                        .multiblur([(10, 0.85), (25, 0.5), (50, 0.5)])
                        .accessibilityHidden(true)
                    Text("Accept Permissions On Your Mac")
                        .font(.title2)
                        .bold()
                        .padding(.horizontal)
                        .padding(.top)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                // It sits after the list in the ZStack; read it first.
                .accessibilitySortPriority(1)
                .accessibilityValue("Apps: \(enabledPlatformNames.joined(separator: ", "))")
                .frame(maxWidth:.infinity)
                .background(GeometryReader {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .padding(.bottom, -30)
                        .preference(key: HeaderSizePreferenceKey.self, value: $0.size.height)
                })
                .onPreferenceChange(HeaderSizePreferenceKey.self) { value in
                    self.headerHeight = value
                }
                VStack{
                    Spacer()
                    BottomButtonPanel(height: $bottomPanelHeight){
                        actionButtons
                            .padding()
                    }
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .navigationTitle("")
    }

    private var enabledPlatformNames: [String] {
        PlatformRegistry.allPlatforms
            .filter { enabledPlatforms.contains($0.id) }
            .map { $0.name }
    }

    private func state(of platformId: String) -> PlatformPermissionState {
        permissionStates[platformId] ?? .initial
    }

    /// The grant this row can offer instructions for; nil unless it failed with
    /// a named one.
    private func fixableKind(for platformId: String) -> PermissionKind? {
        if case .failed(let kind) = state(of: platformId) { return kind }
        return nil
    }

    /// Purely visual — the row ignores its children, so a label added here could
    /// never be read. Spoken status comes from `spokenStatus`.
    private func permissionStatusIcon(for platformId: String) -> some View {
        Group {
            switch permissionStates[platformId] ?? .initial {
            case .initial:
                EmptyView()
            case .checking:
                ProgressView()
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10){
            Button(action: onComplete) {
                Text("Skip")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .tint(.accentColor)
            .disabled(connectionManager.connectionState != .connected)
            .opacity(connectionManager.connectionState == .connected ? 1 : 0.5)
            .accessibilityHint("Skip permission checks and continue")

            Button {
                Task { await checkAllPermissions() }
            } label: {
                Text("Check Permissions")
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .glassPillLabel(tint: .accentColor)
                    .fontWeight(.bold)
                    .multiblur([(10,0.25), (20,0.35), (50,0.5),  (100,0.5)])
            }
            .glassPillButtonStyle()
            .frame(maxWidth: .infinity)
            .disabled(isChecking || allPermissionsGranted || connectionManager.connectionState != .connected)
            .opacity(connectionManager.connectionState == .connected ? 1 : 0.5)
            .accessibilityHint(isChecking ? "Currently checking permissions" : allPermissionsGranted ? "All permissions already granted" : "Check app permissions on your Mac")
            // One button, so "Learn why" isn't a sliver of a tap target.
            Button {
                showingPermissionsNameExplanation = true
            } label: {
                (Text("This may open permission dialogs for “sshd-keygen-wrapper” on your Mac. ")
                    .foregroundStyle(.secondary)
                    + Text("Learn why")
                    .foregroundStyle(.tint))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityHint("Explains why the dialogs name sshd-keygen-wrapper instead of Control")
            // A sheet, not an alert: alerts can't carry the screenshot.
            .sheet(isPresented: $showingPermissionsNameExplanation) {
                PermissionsNameExplanationSheet()
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var allPermissionsGranted: Bool {
        enabledPlatforms.allSatisfy { platformId in
            permissionStates[platformId] == .granted
        }
    }

    private var isChecking: Bool {
        enabledPlatforms.contains { platformId in
            permissionStates[platformId] == .checking
        }
    }

    private func checkAllPermissions() async {
        // A second tap while a sweep is running would double every command.
        guard !isCheckSweepRunning else { return }
        isCheckSweepRunning = true
        defer { isCheckSweepRunning = false }

        viewLog("PermissionsView: Starting permission check for all platforms", view: "PermissionsView")
        viewLog("Enabled platforms: \(enabledPlatforms)", view: "PermissionsView")

        for platformId in enabledPlatforms {
            if case .failed = permissionStates[platformId] ?? .initial {
                viewLog("Resetting failed state for \(platformId)", view: "PermissionsView")
                permissionStates[platformId] = .initial
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for platformId in enabledPlatforms {
                if permissionStates[platformId] != .granted {
                    group.addTask {
                        await checkPermission(for: platformId)
                    }
                }
            }
        }
        
        viewLog("Permission check complete. Results:", view: "PermissionsView")
        for platformId in enabledPlatforms {
            viewLog("  \(platformId): \(permissionStates[platformId] ?? .initial)", view: "PermissionsView")
        }

        // The all-granted case is announced by the success transition instead.
        if !allPermissionsGranted {
            let grantedCount = enabledPlatforms.filter { permissionStates[$0] == .granted }.count
            // Named with the grant each needs, so the summary is actionable.
            let failedNames = PlatformRegistry.allPlatforms
                .filter { enabledPlatforms.contains($0.id) }
                .compactMap { platform -> String? in
                    guard case .failed = state(of: platform.id) else { return nil }
                    return "\(platform.name), \(state(of: platform.id).spokenStatus)"
                }
            var summary = "Permission check finished. \(grantedCount) of \(enabledPlatforms.count) granted."
            if !failedNames.isEmpty {
                summary += " Needs attention: \(failedNames.joined(separator: "; "))."
            }
            AccessibilityNotification.Announcement(summary).post()
        }
    }

    private func checkPermission(for platformId: String) async {
        guard let platform = PlatformRegistry.allPlatforms.first(where: { $0.id == platformId }) else { 
            viewLog("❌ Platform not found: \(platformId)", view: "PermissionsView")
            return 
        }

        viewLog("Starting permission check for \(platform.name)", view: "PermissionsView")
        permissionStates[platformId] = .checking

        // Frontmost-targeting platforms have no app to resolve, and activating
        // anything would change what's frontmost. Their `fetchState()` triggers
        // the prompt on its own.
        if !platform.targetsFrontmostApp {
            let activateScript = """
            tell application "\(platform.name)"
                activate
            end tell
            """

            viewLog("Activating \(platform.name)...", view: "PermissionsView")
            let activateResult = await withCheckedContinuation { continuation in
                connectionManager.executeCommandIsolated(activateScript, description: "\(platform.name): activate") { result in
                    continuation.resume(returning: result)
                }
            }

            switch activateResult {
            case .success:
                viewLog("✓ \(platform.name) activated successfully", view: "PermissionsView")
            case .failure(let error):
                viewLog("⚠️ \(platform.name) activation failed: \(error)", view: "PermissionsView")
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let stateScript = platform.fetchState()

        viewLog("Checking permissions for \(platform.name) by fetching state...", view: "PermissionsView")
        let stateResult = await withCheckedContinuation { continuation in
            connectionManager.executeCommandIsolated(stateScript, description: "\(platform.name): fetch status") { result in
                continuation.resume(returning: result)
            }
        }

        switch stateResult {
        case .success(let output):
            viewLog("Permission check result for \(platform.name):", view: "PermissionsView")
            viewLog("Output: \(output)", view: "PermissionsView")
            
            if output.trimmingCharacters(in: .whitespacesAndNewlines) == ScriptTokens.accessibilityRequired {
                viewLog("❌ \(platform.name): Accessibility permission needed", view: "PermissionsView")
                permissionStates[platformId] = .failed(.accessibility)
            } else if ScriptTokens.indicatesAssistiveAccessDenied(output) {
                // IINA/mpv/TV never return the sentinel — their scripts carry no
                // assistive-access guard — so this is where they're caught.
                viewLog("❌ \(platform.name): Accessibility permission needed", view: "PermissionsView")
                permissionStates[platformId] = .failed(.accessibility)
            } else if output.contains("Not authorized to send Apple events") {
                viewLog("❌ \(platform.name): Permission denied", view: "PermissionsView")
                permissionStates[platformId] = .failed(.automation)
            } else {
                // TODO: a closed app can't be exercised, so it lands here as
                // granted — IINA/mpv return their own "Not running" status, and
                // the `activate` above only waits 500ms for a cold launch. The
                // control screen catches it reactively on first use.
                viewLog("✓ \(platform.name): Permission granted", view: "PermissionsView")
                permissionStates[platformId] = .granted
            }
        case .failure(let error):
            viewLog("Initial permission check failed for \(platform.name): \(error)", view: "PermissionsView")
            // No response usually means the prompt is still up. Bounded by wall
            // clock, not attempts: each can block ~6s in the command watchdog, so
            // a count is a wildly variable bound.
            let deadline = Date().addingTimeInterval(60)
            var attempts = 0
            while Date() < deadline {

                // After a timeout the shell channel is being rebuilt; retrying
                // sooner lands on a cold interpreter.
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                viewLog("Retry attempt \(attempts + 1) for \(platform.name)", view: "PermissionsView")
                let retryResult = await withCheckedContinuation { continuation in
                    connectionManager.executeCommandIsolated(stateScript, description: "\(platform.name): fetch status (retry \(attempts + 1))") { result in
                        continuation.resume(returning: result)
                    }
                }

                switch retryResult {
                case .success(let output):
                    viewLog("Retry successful for \(platform.name)", view: "PermissionsView")
                    viewLog("Output: \(output)", view: "PermissionsView")
                    
                    if output.trimmingCharacters(in: .whitespacesAndNewlines) == ScriptTokens.accessibilityRequired
                        || ScriptTokens.indicatesAssistiveAccessDenied(output) {
                        viewLog("❌ \(platform.name): Accessibility permission needed", view: "PermissionsView")
                        permissionStates[platformId] = .failed(.accessibility)
                    } else if output.contains("Not authorized to send Apple events") {
                        viewLog("❌ \(platform.name): Permission still denied after retry", view: "PermissionsView")
                        permissionStates[platformId] = .failed(.automation)
                    } else {
                        viewLog("✓ \(platform.name): Permission granted after retry", view: "PermissionsView")
                        permissionStates[platformId] = .granted
                    }
                    return
                case .failure(let error):
                    viewLog("Retry \(attempts + 1) failed for \(platform.name): \(error)", view: "PermissionsView")
                    attempts += 1
                }
            }

            viewLog("❌ \(platform.name): Permission check timed out after \(attempts) attempts (60s)", view: "PermissionsView")
            permissionStates[platformId] = .failed(nil)
        }
    }
}

/// Why macOS's permission dialogs say "sshd-keygen-wrapper" and not "Control",
/// led by a screenshot so the name is recognizable when it appears.
private struct PermissionsNameExplanationSheet: View {
    @ObservedObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 8) {
                        Image("sshd-keygen-wrapper-dialog-cropped")
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .accessibilityLabel("A macOS dialog showing: “sshd-keygen-wrapper” wants access to control “Music”, with Don’t Allow and Allow buttons")
                        Text("Example dialog.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 10)
                    .accessibilityElement(children: .combine)

                    Text("Why “sshd-keygen-wrapper”?")
                        .font(.title2.bold())
                        .multilineTextAlignment(.leading)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 16){
                        Group{
                            Text("Control lives on your phone. It never runs on your Mac, though it does send *commands* to it.")
                            Text("Those commands are sent via macOS's built-in Remote Login, and sshd-keygen-wrapper is the system process that delivers them.")
                            Text("Note: if you ever want to manage these permissions later, they're found under System Settings > Privacy & Security > Automation > sshd-keygen-wrapper.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                HStack {
                    Text("OK")
                        .multiblur([(10,0.25), (50,0.35)])
                }
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .glassPillLabel()
                .fontWeight(.bold)
            }
            .glassPillButtonStyle(tint: .accentColor)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial)
        .themeTint(preferences.tintColorValue)
        .presentationDetents([.fraction(0.9), .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview("Why sshd-keygen-wrapper sheet") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PermissionsNameExplanationSheet()
        }
}

#Preview {
    let client = SSHClient()
    client.connect(
        host: ProcessInfo.processInfo.environment["ENV_HOST"] ?? "",
        username: ProcessInfo.processInfo.environment["ENV_USER"] ?? "",
        password: ProcessInfo.processInfo.environment["ENV_PASS"] ?? ""
    ) { _ in }

    return PermissionsView(
        host: ProcessInfo.processInfo.environment["ENV_HOST"] ?? "",
        displayName: ProcessInfo.processInfo.environment["ENV_NAME"] ?? "",
        username: ProcessInfo.processInfo.environment["ENV_USER"] ?? "",
        password: ProcessInfo.processInfo.environment["ENV_PASS"] ?? "",
        enabledPlatforms: ["music", "vlc", "tv", "safari", "chrome"],
        onComplete: {}
    )
}
