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
    @State private var bottomPanelHeight: CGFloat = 0
    @State private var showAppList: Bool = false
    
    private var availablePlatforms: [any AppPlatform] {
        // Registry order, which leads with Keyboard — the pager shows the
        // same order, so this list previews it.
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
            ScrollView(showsIndicators: false) {
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
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(platform.name)
                                        if platform.experimental {
                                            Image(systemName: "flask.fill")
                                                .foregroundStyle(.tint)
                                                .font(.caption)
                                                .accessibilityLabel("Experimental")
                                        }
                                    }
                                    if let listDescription = platform.listDescription {
                                        Text(listDescription)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
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
                        .animation(.spring(), value: selectedPlatforms)
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
            .opacity(connectionManager.connectionState == .connected ? 1 : 0.3)
            .animation(.spring(), value: connectionManager.connectionState)

            VStack(spacing: 8) {
                Image(systemName: "macbook.and.iphone")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 40)
                    .padding(0)
                    .foregroundStyle(.tint, .quaternary)
                    .padding(.bottom, -20)
                    .accessibilityHidden(true)
                Text("Choose apps to control")
                    .font(.title2)
                    .bold()
                    .padding(.horizontal)
                    .padding(.top)
                Text("You can change these anytime.")
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            // One heading element instead of a header trait on each fragment.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // The header sits after the list in the ZStack; read it first, with
            // a running summary of the selection. Count only visible platforms:
            // a saved selection can hold ids no longer listed (e.g. a disabled
            // experimental app), which would announce "8 of 7 apps selected".
            .accessibilitySortPriority(1)
            .accessibilityValue("\(visibleSelectionCount) of \(availablePlatforms.count) apps selected")
            .frame(maxWidth:.infinity)
            .multilineTextAlignment(.center)
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
                    Button(action: {
                        viewLog("Selected platforms: \(selectedPlatforms)", view: "ChooseAppsView")
                        onComplete(selectedPlatforms)
                    }) {
                        Text(isReconfiguration ? "Update" : "Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .glassPillLabel(tint: .accentColor)
                            .fontWeight(.bold)
                            .multiblur([(10,0.25), (20,0.85), (50,0.85),  (100,0.85)])
                    }
                    .glassPillButtonStyle()
                    .padding()
                    .frame(maxWidth: .infinity)
                    .disabled(selectedPlatforms.isEmpty || connectionManager.connectionState != .connected)
                    .opacity(connectionManager.connectionState == .connected ? 1 : 0.5)
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .navigationTitle("")
        .navigationBarBackButtonHidden(false)
        .onAppear {
            viewLog("ChooseAppsView: View appeared", view: "ChooseAppsView")
            updateSelectedPlatforms()
            setupSSHConnection()
        }
        .onChange(of: initialSelection) { _, newValue in
            updateSelectedPlatforms()
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

    /// Selected platforms that are actually in the visible list.
    private var visibleSelectionCount: Int {
        availablePlatforms.filter { selectedPlatforms.contains($0.id) }.count
    }

    private func updateSelectedPlatforms() {
        // Initialize selected platforms based on initialSelection or defaultEnabled property
        if let initialSelection = initialSelection {
            selectedPlatforms = initialSelection
        } else {
            selectedPlatforms = Set(availablePlatforms.filter { $0.defaultEnabled }.map { $0.id })
        }
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
