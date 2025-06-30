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

struct PermissionsView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let enabledPlatforms: Set<String>
    let onComplete: () -> Void

    @StateObject private var connectionManager = SSHConnectionManager.shared
    @State private var permissionStates: [String: PlatformPermissionState] = [:]
    @State private var permissionsGranted: Bool = false
    @State private var showSuccess: Bool = false
    @State private var headerHeight: CGFloat = 0
    @State private var showAppList: Bool = false
    @State private var showingConnectionLostAlert = false
    @State private var showingError = false
    @State private var connectionError: (title: String, message: String)?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

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

            // Set up connection lost handler
            connectionManager.setConnectionLostHandler { @MainActor in
                showingConnectionLostAlert = true
            }

            // Connect to SSH
            connectToSSH()

            // If permissions are already granted, show success right away
            if allPermissionsGranted {
                permissionsGranted = true
            }
        }
        .onChange(of: scenePhase, { oldPhase, newPhase in
            if newPhase == .active {
                // Check connection health first, then reconnect if needed
                Task {
                    if connectionManager.connectionState == .connected {
                        do {
                            try await connectionManager.verifyConnectionHealth()
                            viewLog("✓ PermissionsView: Connection health verified", view: "PermissionsView")
                        } catch {
                            viewLog("❌ PermissionsView: Connection health check failed: \(error)", view: "PermissionsView")
                            connectToSSH()
                        }
                    } else {
                        connectToSSH()
                    }
                }
            }
            connectionManager.handleScenePhaseChange(from: oldPhase, to: newPhase)
        })
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
        .onChange(of: allPermissionsGranted) {
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

    private func connectToSSH() {
        connectionManager.handleConnection(
            host: host,
            username: username,
            password: password,
            onSuccess: { },
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

    private var successView: some View {
        VStack {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .frame(width: 50, height: 50)
                .foregroundStyle(.tint)
                .padding(.bottom, 10)
            Text("You're all set")
                .font(.title2)
                .bold()
        }
        .padding()
    }

    /// The "Main Permissions" UI that appears until the user grants permissions
    private var mainPermissionsView: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .top){
                ScrollView(showsIndicators: false) {
                    HStack{EmptyView()}.frame(height: headerHeight)
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(enabledPlatforms), id: \.self) { platformId in
                            if let platform = PlatformRegistry.allPlatforms.first(where: { $0.id == platformId }) {
                                HStack {
                                    Text(platform.name)
                                    Spacer()
                                    permissionStatusIcon(for: platformId)
                                }
                                .padding()
                                .background(.ultraThinMaterial.opacity(0.5))
                                .cornerRadius(12)
                                .opacity(permissionStates[platformId] != .initial ? 1 : 0.5)
                                .animation(.spring(), value: permissionStates[platformId])
                            }
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
                .frame(maxWidth:.infinity)
                .background(GeometryReader {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .padding(.bottom, -30)
                        .preference(key: headerSizePreferenceKey.self, value: $0.size.height)
                })
                .onPreferenceChange(headerSizePreferenceKey.self) { value in
                    self.headerHeight = value
                    print("Header Height: \(headerHeight)")
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
    }

    struct headerSizePreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value += nextValue()
        }
    }

    private func permissionStatusIcon(for platformId: String) -> some View {
        Group {
            switch permissionStates[platformId] ?? .initial {
            case .initial:
                EmptyView()
                    .accessibilityHidden(true)
            case .checking:
                ProgressView()
                    .accessibilityLabel("Checking permissions")
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Permissions granted")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Permission check failed")
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
                    .tint(.accentColor)
                    .foregroundStyle(.tint)
                    .fontWeight(.bold)
                    .multiblur([(10,0.25), (20,0.35), (50,0.5),  (100,0.5)])
            }
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .buttonStyle(.bordered)
            .tint(.gray)
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
    }

    func executeCommand(_ command: String, description: String? = nil) async -> Result<String, Error> {
        let wrappedCommand = ShellCommandUtilities.wrapAppleScriptForBash(command)

        return await withCheckedContinuation { continuation in
            connectionManager.executeCommandWithNewChannel(wrappedCommand, description: description) { result in
                continuation.resume(returning: result)
            }
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
        let activateCommand = ShellCommandUtilities.wrapAppleScriptForBash(activateScript)

        viewLog("Activating \(platform.name)...", view: "PermissionsView")
        let activateResult = await withCheckedContinuation { continuation in
            connectionManager.executeCommandWithNewChannel(activateCommand, description: "\(platform.name): activate") { result in
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
        let stateCommand = ShellCommandUtilities.wrapAppleScriptForBash(platform.fetchState())

        viewLog("Checking permissions for \(platform.name) by fetching state...", view: "PermissionsView")
        let stateResult = await withCheckedContinuation { continuation in
            connectionManager.executeCommandWithNewChannel(stateCommand, description: "\(platform.name): fetch status") { result in
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
            // Keep checking - no response likely means waiting for user to accept permissions
            // Keep the checking state and start a retry loop
            var attempts = 0
            while attempts < 60 { // Try for up to 30 seconds

                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay between checks

                viewLog("Retry attempt \(attempts + 1) for \(platform.name)", view: "PermissionsView")
                let retryResult = await withCheckedContinuation { continuation in
                    connectionManager.executeCommandWithNewChannel(stateCommand, description: "\(platform.name): fetch status (retry \(attempts + 1))") { result in
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
            viewLog("❌ \(platform.name): Permission check timed out after \(attempts) attempts", view: "PermissionsView")
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
