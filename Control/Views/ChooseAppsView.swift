import SwiftUI
import MultiBlur

struct ChooseAppsView: View, SSHConnectedView {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let initialSelection: Set<String>?
    let onComplete: (Set<String>) -> Void
    
    private var isReconfiguration: Bool {
        initialSelection != nil
    }

    @StateObject internal var connectionManager = SSHConnectionManager.shared
    @StateObject private var platformRegistry = PlatformRegistry()
    @State private var headerHeight: CGFloat = 0
    @State private var showAppList: Bool = false
    
    private var availablePlatforms: [any AppPlatform] {
        let nonExperimental = platformRegistry.nonExperimentalPlatforms
        let enabledExperimental = platformRegistry.experimentalPlatforms.filter { 
            platformRegistry.enabledExperimentalPlatforms.contains($0.id) 
        }
        return nonExperimental + enabledExperimental
    }

    @State private var selectedPlatforms: Set<String> = []
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
        ZStack(alignment: .top) {
            ScrollView {
                HStack{EmptyView()}.frame(height: headerHeight)
                VStack(spacing: 8) {
                    ForEach(availablePlatforms, id: \.id) { platform in
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
                                HStack {
                                    Text(platform.name)
                                    if platform.experimental {
                                        Image(systemName: "flask.fill")
                                            .foregroundStyle(.tint)
                                            .font(.caption)
                                    }
                                }
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
                        Text(isReconfiguration ? "Update" : "Continue")
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

            // Initialize selected platforms based on initialSelection or defaultEnabled property
            if let initialSelection = initialSelection {
                selectedPlatforms = initialSelection
                viewLog("ChooseAppsView: Using provided initial selection: \(initialSelection)", view: "ChooseAppsView")
            } else {
                selectedPlatforms = Set(availablePlatforms.filter { $0.defaultEnabled }.map { $0.id })
                viewLog("ChooseAppsView: Using default enabled platforms: \(selectedPlatforms)", view: "ChooseAppsView")
            }
            
            // Set up SSH connection
            setupSSHConnection()
        }
        .onChange(of: scenePhase, handleScenePhaseChange)
        .onDisappear {
            viewLog("ChooseAppsView: View disappeared", view: "ChooseAppsView")
        }
        .alert("Connection Lost", isPresented: showingConnectionLostAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text(SSHError.timeout.formatError(displayName: displayName).message)
        }
        .alert(isPresented: showingError) { connectionErrorAlert() }
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
            initialSelection: nil,
            onComplete: { _ in }
        )
    }
}
