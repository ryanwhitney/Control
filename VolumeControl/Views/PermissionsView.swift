import SwiftUI

enum PlatformPermissionState: Equatable {
    case initial
    case checking
    case granted
    case failed(String)
    
    static func == (lhs: PlatformPermissionState, rhs: PlatformPermissionState) -> Bool {
        switch (lhs, rhs) {
        case (.initial, .initial):
            return true
        case (.checking, .checking):
            return true
        case (.granted, .granted):
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
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .foregroundStyle(.blue)
                
                Text("App Permissions")
                    .font(.title2)
                    .bold()
                
                Text("Grant permissions for \(displayName)")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                
                Text("When prompted on your Mac, click 'OK' to allow control")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            
            platformList
            
            actionButton
        }
        .padding()
        .frame(maxWidth: 400)
        .onAppear {
            // Initialize states
            for platformId in enabledPlatforms {
                if permissionStates[platformId] == nil {
                    permissionStates[platformId] = .initial
                }
            }
        }
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
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
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
            case .initial:
                Text("Waiting to check...")
                    .foregroundStyle(.secondary)
            case .checking:
                Text("Checking permissions...")
                    .foregroundStyle(.secondary)
            case .granted:
                Text("Permission granted")
                    .foregroundStyle(.green)
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
        Group {
            if allPermissionsGranted {
                Button(action: onComplete) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await checkAllPermissions() }
                } label: {
                    Text(anyPermissionsChecked ? "Try Again" : "Check Permissions")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
    
    private func executeCommand(_ command: String, description: String? = nil) async throws -> String {
        let wrappedCommand = """
        osascript << 'APPLESCRIPT'
        try
            \(command)
        on error errMsg
            return errMsg
        end try
        APPLESCRIPT
        """
        
        return try await withCheckedThrowingContinuation { continuation in
            sshClient.executeCommandWithNewChannel(wrappedCommand, description: description) { result in
                continuation.resume(with: result)
            }
        }
    }
    
    private func checkPermission(for platformId: String) async {
        guard let platform = PlatformRegistry.allPlatforms.first(where: { $0.id == platformId }) else { return }
        
        permissionStates[platformId] = .checking
        
        do {
            // First check if the app is running
            let isRunningScript = platform.isRunningScript()
            let output = try await executeCommand(isRunningScript, description: "\(platform.name): check if running")
            
            let isRunning = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "true"
            if isRunning {
                // App is running, fetch its state
                let script = platform.fetchState()
                let stateOutput = try await executeCommand(script, description: "\(platform.name): fetch status")
                
                // Check if the output contains an authorization error
                if stateOutput.contains("Not authorized to send Apple events") {
                    permissionStates[platformId] = .failed("Permission needed")
                } else {
                    permissionStates[platformId] = .granted
                }
            } else {
                permissionStates[platformId] = .failed("App not running")
            }
        } catch {
            permissionStates[platformId] = .failed("Connection error")
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

// Delete the mock implementation 

