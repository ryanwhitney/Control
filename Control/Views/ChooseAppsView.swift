import SwiftUI
import MultiBlur

struct ChooseAppsView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let onComplete: (Set<String>) -> Void

    @StateObject private var connectionManager = SSHConnectionManager.shared
    @StateObject private var platformRegistry = PlatformRegistry()
    @State private var headerHeight: CGFloat = 0
    @State private var showAppList: Bool = false

    @State private var selectedPlatforms: Set<String> = []
    @State private var showingConnectionLostAlert = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                HStack{EmptyView()}.frame(height: headerHeight)
                VStack(spacing: 8) {
                    ForEach(platformRegistry.platforms, id: \.id) { platform in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { selectedPlatforms.contains(platform.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedPlatforms.insert(platform.id)
                                    } else {
                                        selectedPlatforms.remove(platform.id)
                                    }
                                }
                            )) {
                                Text(platform.name)
                                    .padding()
                            }
                            .padding(.trailing)
                            .foregroundStyle(.primary)
                        }
                        .background(.ultraThinMaterial.opacity(0.5))
                        .cornerRadius(14)
                        .onTapGesture {
                            if selectedPlatforms.contains(platform.id) {
                                selectedPlatforms.remove(platform.id)
                            } else {
                                selectedPlatforms.insert(platform.id)
                            }
                        }
                        .opacity(selectedPlatforms.contains(platform.id) ? 1 : 0.5)
                        .animation(.spring(), value: selectedPlatforms)
                        .accessibilityAddTraits(.isToggle)
                    }
                }
                .padding()
            }
            .opacity(connectionManager.connectionState == .connected ? 1 : 0.3)
            .animation(.spring(), value: connectionManager.connectionState)
            
            /// Header
            VStack(spacing: 8) {
                Image(systemName: "macbook.and.iphone")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 40)
                    .padding(0)
                    .foregroundStyle(.tint, .quaternary)
                    .padding(.bottom, -20)
                    .accessibilityHidden(true)
                Text("Which apps would you like to control?")
                    .font(.title2)
                    .bold()
                    .padding(.horizontal)
                    .padding(.top)
                Text("You can change these anytime.")
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            .frame(maxWidth:.infinity)
            .multilineTextAlignment(.center)
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
                    Button(action: {
                        viewLog("Selected platforms: \(selectedPlatforms)", view: "ChooseAppsView")
                        onComplete(selectedPlatforms)
                    }) {
                        Text("Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .tint(.accentColor)
                            .foregroundStyle(.tint)
                            .fontWeight(.bold)
                            .multiblur([(10,0.25), (20,0.35), (50,0.5),  (100,0.5)])
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding()
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .frame(maxWidth: .infinity)
                    .disabled(selectedPlatforms.isEmpty || connectionManager.connectionState != .connected)
                    .opacity(connectionManager.connectionState == .connected ? 1 : 0.5)
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .onAppear {
            viewLog("ChooseAppsView: View appeared", view: "ChooseAppsView")
            
            // Show connection metadata without exposing sensitive info
            let isLocal = host.contains(".local")
            let connectionType = isLocal ? "SSH over Bonjour (.local)" : "SSH over TCP/IP"
            let hostRedacted = String(host.prefix(3)) + "***"
            
            viewLog("Target: \(hostRedacted)", view: "ChooseAppsView")
            viewLog("Protocol: \(connectionType)", view: "ChooseAppsView")
            viewLog("Display name: \(String(displayName.prefix(3)))***", view: "ChooseAppsView")

            // Initialize selected platforms based on their defaultEnabled property
            selectedPlatforms = Set(platformRegistry.platforms.filter { $0.defaultEnabled }.map { $0.id })
            
            // Set up connection lost handler
            connectionManager.setConnectionLostHandler { @MainActor in
                viewLog("⚠️ ChooseAppsView: Connection lost handler triggered", view: "ChooseAppsView")
                showingConnectionLostAlert = true
            }
            connectToSSH()
        }
        .onChange(of: scenePhase, { oldPhase, newPhase in
            viewLog("ChooseAppsView: Scene phase changed from \(oldPhase) to \(newPhase)", view: "ChooseAppsView")
            if newPhase == .active {
                connectToSSH()
            }
            connectionManager.handleScenePhaseChange(from: oldPhase, to: newPhase)
        })
        .onDisappear {
            viewLog("ChooseAppsView: View disappeared", view: "ChooseAppsView")
        }
        .alert("Connection Lost", isPresented: $showingConnectionLostAlert) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text(SSHError.timeout.formatError(displayName: displayName).message)
        }
    }
    
    private func connectToSSH() {
        viewLog("ChooseAppsView: Connecting to SSH", view: "ChooseAppsView")
        viewLog("Connection manager state: \(connectionManager.connectionState)", view: "ChooseAppsView")
        
        connectionManager.handleConnection(
            host: host,
            username: username,
            password: password,
            onSuccess: { 
                viewLog("✓ ChooseAppsView: SSH connection successful", view: "ChooseAppsView")
            },
            onError: { error in
                viewLog("❌ ChooseAppsView: SSH connection failed: \(error)", view: "ChooseAppsView")
            }
        )
    }

}

struct headerSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

#Preview {
    return NavigationStack {
        ChooseAppsView(
            host: ProcessInfo.processInfo.environment["ENV_HOST"] ?? "",
            displayName: ProcessInfo.processInfo.environment["ENV_NAME"] ?? "",
            username: ProcessInfo.processInfo.environment["ENV_USER"] ?? "",
            password: ProcessInfo.processInfo.environment["ENV_PASS"] ?? "",
            onComplete: { _ in }
        )
    }
}
