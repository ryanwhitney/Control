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
    let hostname: String
    let displayName: String
    let sshClient: SSHClientProtocol
    let enabledPlatforms: Set<String>
    let onComplete: () -> Void
    
    @State private var permissionStates: [String: PlatformPermissionState] = [:]
    @State private var permissionsGranted: Bool = false
    @State private var showSuccess: Bool = false
    @State private var headerHeight: CGFloat = 0
    @State private var showAppList: Bool = false



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
    
    /// The “Main Permissions” UI that appears until the user grants permissions
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
            Button {
                Task { await checkAllPermissions() }
            } label: {
                Text( "Check Permissions")
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
            .disabled(isChecking || allPermissionsGranted)

            Text("This may open Permissions Dialogs on \(hostname). [Learn More…](systempreferences://) ")
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
        sshClient: SSHClient(),
        enabledPlatforms: ["music", "vlc", "tv", "safari", "chrome"],
        onComplete: {}
    )
}

