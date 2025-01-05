import SwiftUI

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
    let hostname: String
    let displayName: String
    let sshClient: SSHClientProtocol
    let enabledPlatforms: Set<String>
    let onComplete: () -> Void

    @State private var permissionStates: [String: PlatformPermissionState] = [:]
    @State private var permissionsGranted: Bool = false
    @State private var showSuccess: Bool = false


    var body: some View {
        ZStack {
            // SUCCESS VIEW
            successView
            // Keep it around, but drive its visibility via opacity
                .opacity(showSuccess ? 1 : 0)
            // Hide from accessibility if fully invisible
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

            // If permissions are already granted, show success right away
            if allPermissionsGranted {
                permissionsGranted = true
            }
        }
        // Watch for changes to allPermissionsGranted, then do a staged animation
        .onChange(of: allPermissionsGranted) {
            print("PERMISSIONS CHANGED: " + allPermissionsGranted.description)
            print("PERMISSIONS CHANGED BOOL: " + permissionsGranted.description)
            print("SHOWSUCCESS: " + showSuccess.description)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    permissionsGranted = true
                }
            }
            // 2) Once main UI is fully transparent, fade in success UI
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    showSuccess = true
                }
            }
        }
    }

    private var successView: some View {
        VStack {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .frame(width: 50, height: 50)
                .foregroundColor(.accentColor)
                .padding(.bottom, 10)

            Text("Permissions look good.")
                .font(.title2)
                .bold()

            VStack {
                Button(action: onComplete) {
                    HStack{
                        Text("Take Control")
                        Image(systemName: "arrow.right")
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
            }
            .padding()
        }
        .padding()
    }

    /// The “Main Permissions” UI that appears until the user grants permissions
    private var mainPermissionsView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Accept Permissions On Your Mac")
                    .font(.title2)
                    .bold()

                Text("Allows Control to command only the specific apps you selected.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }

            platformList
            actionButton
        }
        .padding()
    }


    private var platformList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(enabledPlatforms), id: \.self) { platformId in
                    if let platform = PlatformRegistry.allPlatforms.first(where: { $0.id == platformId }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(platform.name)
                                permissionStateView(for: platformId)
                            }
                            Spacer()
                            permissionStatusIcon(for: platformId)
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }

    private func permissionStateView(for platformId: String) -> some View {
        Group {
            switch permissionStates[platformId] ?? .initial {
            case .initial, .checking, .granted:
                EmptyView()
            case .failed(let error):
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    private func permissionStatusIcon(for platformId: String) -> some View {
        Group {
            switch permissionStates[platformId] ?? .initial {
            case .initial:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
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

    private var actionButton: some View {
        VStack(spacing: 10){
            Button(action: onComplete) {
                Text("Skip")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .tint(.accentColor)
            ZStack {
                Text("Open Permissions on Mac")
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.tint)
                    .fontWeight(.bold)
                    .blur(radius: 50)
                    .accessibilityHidden(true)
                Text("Open Permissions on Mac")
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.tint)
                    .fontWeight(.bold)
                    .blur(radius: 10)
                    .accessibilityHidden(true)
                Text("Open Permissions on Mac")
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.tint)
                    .fontWeight(.bold)
                    .blur(radius: 20)
                    .accessibilityHidden(true)

                Button {
                    Task { await checkAllPermissions() }
                } label: {
                    Text( "Open Permissions on Mac")
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .tint(.accentColor)
                        .fontWeight(.bold)
                }
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(isChecking)
            }
        }
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

    private var anyPermissionsChecked: Bool {
        enabledPlatforms.contains { platformId in
            if case .initial = permissionStates[platformId] ?? .initial {
                return false
            }
            return true
        }
    }

    private func checkAllPermissions() async {
        // Reset failed states to initial
        for platformId in enabledPlatforms {
            if case .failed = permissionStates[platformId] ?? .initial {
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
    }

    func executeCommand(_ command: String, description: String? = nil) async -> Result<String, Error> {
        let wrappedCommand = """
        osascript << 'APPLESCRIPT'
        try
            \(command)
        on error errMsg
            return errMsg
        end try
        APPLESCRIPT
        """

        return await withCheckedContinuation { continuation in
            sshClient.executeCommandWithNewChannel(wrappedCommand, description: description) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func checkPermission(for platformId: String) async {
        guard let platform = PlatformRegistry.allPlatforms.first(where: { $0.id == platformId }) else { return }

        permissionStates[platformId] = .checking

        // First activate the app
        let activateCommand = """
        osascript << 'APPLESCRIPT'
        tell application "\(platform.name)"
            activate
        end tell
        APPLESCRIPT
        """

        _ = await withCheckedContinuation { continuation in
            sshClient.executeCommandWithNewChannel(activateCommand, description: "\(platform.name): activate") { result in
                continuation.resume(returning: result)
            }
        }

        // Add a small delay to allow the app to fully activate
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        // Then check permissions by fetching state
        let stateCommand = """
        osascript << 'APPLESCRIPT'
        try
            \(platform.fetchState())
        on error errMsg
            return errMsg
        end try
        APPLESCRIPT
        """

        let stateResult = await withCheckedContinuation { continuation in
            sshClient.executeCommandWithNewChannel(stateCommand, description: "\(platform.name): fetch status") { result in
                continuation.resume(returning: result)
            }
        }

        switch stateResult {
        case .success(let output):
            if output.contains("Not authorized to send Apple events") {
                permissionStates[platformId] = .failed("Permission needed")
            } else {
                permissionStates[platformId] = .granted
            }
        case .failure:
            // Keep checking - no response likely means waiting for user to accept permissions
            permissionStates[platformId] = .failed("Waiting for permission")
        }
    }
}

#Preview {
    let client = SSHClient()
    client.connect(host: "rwhitney-mac.local", username: "ryan", password: "") { _ in }

    return PermissionsView(
        hostname: "rwhitney-mac.local",
        displayName: "Ryan's Mac",
        sshClient: client,
        enabledPlatforms: ["music", "vlc"],
        onComplete: {}
    )
}
