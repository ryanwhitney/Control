import SwiftUI
import MultiBlur

enum PlatformPermissionState: Equatable {
    case initial
    case checking
    case granted
    case failed(String)

    static func == (lhs: PlatformPermissionState, rhs: PlatformPermissionState) -> Bool {
        switch (lhs, rhs) {
        case (.initial, .initial),
            (.checking, .checking),
            (.granted, .granted):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

struct PermissionsView: View, SSHConnectedView {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let enabledPlatforms: Set<String>
    let onComplete: () -> Void

    @StateObject internal var connectionManager = SSHConnectionManager.shared
    @State private var permissionStates: [String: PlatformPermissionState] = [:]
    @State private var isCheckSweepRunning = false
    @State private var permissionsGranted: Bool = false
    @State private var showSuccess: Bool = false
    @State private var headerHeight: CGFloat = 0
    @State private var showAppList: Bool = false
    @State private var _showingConnectionLostAlert = false
    @State private var _showingError = false
    @State private var _connectionError: (title: String, message: String)?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - SSHConnectedView Protocol Properties
    var showingConnectionLostAlert: Binding<Bool> { $_showingConnectionLostAlert }
    var connectionError: Binding<(title: String, message: String)?> { $_connectionError }
    var showingError: Binding<Bool> { $_showingError }
    
    // MARK: - SSH Connection Callbacks
    func onSSHConnected() {
        // Connection successful - no specific action needed
    }
    
    func onSSHConnectionFailed(_ error: Error) {
        // Error handling is done automatically by the mixin
    }

    var body: some View {
        ZStack {
            // SUCCESS VIEW
            successView
                .opacity(showSuccess ? 1 : 0)
                .accessibilityHidden(!showSuccess)

            // MAIN PERMISSIONS VIEW
            mainPermissionsView
                .opacity(permissionsGranted ? 0 : 1)
                .accessibilityHidden(permissionsGranted)
        }
        .onAppear {
            // Initialize permission states
            for platformId in enabledPlatforms {
                if permissionStates[platformId] == nil {
                    permissionStates[platformId] = .initial
                }
            }

            setupSSHConnection()

            // If permissions are already granted, show success right away
            if allPermissionsGranted {
                permissionsGranted = true
            }
        }
        .onChange(of: scenePhase, handleScenePhaseChange)
        .alert("Connection Lost", isPresented: showingConnectionLostAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text(SSHError.timeout.formatError(displayName: displayName).message)
        }
        .alert(isPresented: showingError) { connectionErrorAlert() }
        .onChange(of: allPermissionsGranted) {
            // The success state is otherwise conveyed by a visual crossfade only.
            if allPermissionsGranted {
                AccessibilityNotification.Announcement("All permissions granted. You're all set.").post()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation(.spring()) {
                    permissionsGranted = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.spring()) {
                    showSuccess = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                withAnimation(.spring()) {
                    showSuccess = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation(.spring()) {
                    onComplete()
                }
            }
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

    /// The "Main Permissions" UI that appears until the user grants permissions
    private var mainPermissionsView: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .top){
                ScrollView(showsIndicators: false) {
                    HStack{EmptyView()}.frame(height: headerHeight)
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(PlatformRegistry.allPlatforms.filter { enabledPlatforms.contains($0.id) }, id: \.id) { platform in
                            HStack {
                                Text(platform.name)
                                Spacer()
                                permissionStatusIcon(for: platform.id)
                            }
                            .padding()
                            .background(.ultraThinMaterial.opacity(0.5))
                            .cornerRadius(12)
                            .opacity(permissionStates[platform.id] != .initial ? 1 : 0.5)
                            .animation(.spring(), value: permissionStates[platform.id])
                            // One element per row with an explicit status, so the
                            // unchecked state reads "not checked yet" instead of a
                            // bare app name.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(platform.name)
                            .accessibilityValue(statusDescription(for: platform.id))
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
                        .accessibilityHidden(true)
                    Text("Accept Permissions On Your Mac")
                        .font(.title2)
                        .bold()
                        .padding(.horizontal)
                        .padding(.top)
                    Text("Control can only access apps you approve.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                // One heading element instead of a header trait on each fragment.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                // The header sits after the list in the ZStack; read it first,
                // with the app list. (Neutral wording — this string is static,
                // so it must stay true after checks have run.)
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
                    BottomButtonPanel{
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

    /// Spoken status for a row's accessibility value.
    private func statusDescription(for platformId: String) -> String {
        switch permissionStates[platformId] ?? .initial {
        case .initial:
            return "not checked yet"
        case .checking:
            return "checking"
        case .granted:
            return "permission granted"
        case .failed(let reason):
            return reason
        }
    }

    /// Purely visual: the row is one accessibility element (children ignored)
    /// whose spoken status comes from `statusDescription(for:)` — don't add
    /// accessibility labels here, they can never be read.
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

            Text("This may open Permissions Dialogs on \(host).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
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

        // Reset failed states to initial
        for platformId in enabledPlatforms {
            if case .failed = permissionStates[platformId] ?? .initial {
                viewLog("Resetting failed state for \(platformId)", view: "PermissionsView")
                permissionStates[platformId] = .initial
            }
        }

        // Check each platform
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

        // Summarize the sweep for VoiceOver; the all-granted case is announced
        // by the success transition instead.
        if !allPermissionsGranted {
            let grantedCount = enabledPlatforms.filter { permissionStates[$0] == .granted }.count
            let failedNames = PlatformRegistry.allPlatforms
                .filter { enabledPlatforms.contains($0.id) }
                .filter { if case .failed = permissionStates[$0.id] ?? .initial { return true } else { return false } }
                .map { $0.name }
            var summary = "Permission check finished. \(grantedCount) of \(enabledPlatforms.count) granted."
            if !failedNames.isEmpty {
                summary += " Needs attention: \(failedNames.joined(separator: ", "))."
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

        // First activate the app
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

        // Add a small delay to allow the app to fully activate
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        // Then check permissions by fetching state
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
            
            if output.contains("Not authorized to send Apple events") {
                viewLog("❌ \(platform.name): Permission denied", view: "PermissionsView")
                permissionStates[platformId] = .failed("Permission needed")
            } else {
                viewLog("✓ \(platform.name): Permission granted", view: "PermissionsView")
                permissionStates[platformId] = .granted
            }
        case .failure(let error):
            viewLog("Initial permission check failed for \(platform.name): \(error)", view: "PermissionsView")
            // Keep checking - no response likely means waiting for user to accept
            // permissions. Bounded by wall clock, not attempts: each attempt can
            // block ~6s in the command watchdog, so an attempt count is a wildly
            // variable bound (60 attempts was accidentally ~6 minutes).
            let deadline = Date().addingTimeInterval(60)
            var attempts = 0
            while Date() < deadline {

                // 1s between retries: after a timeout the shell channel is being
                // rebuilt, and retrying sooner just lands on a cold interpreter.
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
                    
                    if output.contains("Not authorized to send Apple events") {
                        viewLog("❌ \(platform.name): Permission still denied after retry", view: "PermissionsView")
                        permissionStates[platformId] = .failed("Permission needed")
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

            // If we get here, we've timed out waiting for a response
            viewLog("❌ \(platform.name): Permission check timed out after \(attempts) attempts (60s)", view: "PermissionsView")
            permissionStates[platformId] = .failed("Permission dialog timed out")
        }
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
