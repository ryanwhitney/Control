import SwiftUI
import Combine

struct ControlView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let sshClient: SSHClientProtocol
    let enabledPlatforms: Set<String>
    
    @StateObject private var appController: AppController
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Float = 0.5
    @State private var errorMessage: String?
    @State private var volumeChangeWorkItem: DispatchWorkItem?
    @State private var isReady: Bool = false
    @State private var connectionState: ConnectionState = .disconnected
    @State private var shouldShowLoadingOverlay: Bool = false
    
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case disconnected
        case failed(String)
        
        var isOverlay: Bool {
            switch self {
            case .connecting: return true
            case .disconnected, .failed: return false
            case .connected: return false
            }
        }
        
        static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.connecting, .connecting): return true
            case (.connected, .connected): return true
            case (.disconnected, .disconnected): return true
            case (.failed(let lhsError), .failed(let rhsError)): return lhsError == rhsError
            default: return false
            }
        }
    }
    
    init(host: String, displayName: String, username: String, password: String, sshClient: SSHClientProtocol, enabledPlatforms: Set<String> = Set()) {
        self.host = host
        self.displayName = displayName
        self.username = username
        self.password = password
        self.sshClient = sshClient
        self.enabledPlatforms = enabledPlatforms
        
        // Filter platforms based on enabled set
        let filteredPlatforms = PlatformRegistry.allPlatforms.filter { platform in
            enabledPlatforms.isEmpty || enabledPlatforms.contains(platform.id)
        }
        let registry = PlatformRegistry(platforms: filteredPlatforms)
        
        _appController = StateObject(wrappedValue: AppController(sshClient: sshClient, platformRegistry: registry))
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let totalHeight = geometry.size.height
                let mediaHeight = totalHeight * 6 / 10
                VStack(spacing: 0) {
                    VStack {
                        TabView {
                            ForEach(appController.platforms, id: \.id) { platform in
                                PlatformControl(
                                    platform: platform,
                                    state: Binding(
                                        get: { appController.states[platform.id] ?? AppState(title: "Error") },
                                        set: { appController.states[platform.id] = $0 }
                                    )
                                )
                                .environmentObject(appController)
                            }
                        }
                        .tabViewStyle(.page)
                    }
                    .frame(height: mediaHeight)
                    
                    VStack(spacing: 20) {
                        Spacer()
                        
                        Text("Volume: \(Int(volume * 100))%")
                            .fontWeight(.bold)
                            .fontWidth(.expanded)
                        
                        Slider(value: $volume, in: 0...1, step: 0.01)
                            .padding(.horizontal)
                            .onChange(of: volume) { oldValue, newValue in
                                debounceVolumeChange()
                            }
                        HStack(spacing: 16) {
                            ForEach([-5, -1, 1, 5], id: \.self) { adjustment in
                                Button {
                                    adjustVolume(by: adjustment)
                                } label: {
                                    Text(adjustment > 0 ? "+\(adjustment)" : "\(adjustment)")
                                }
                                .buttonStyle(CircularButtonStyle())
                            }
                        }
                        Spacer()
                    }
                    
                }
            }
        }
        .padding()
        .navigationTitle(displayName)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await appController.updateAllStates()
                    }
                }
            }
        }
        .onAppear {
            connectToSSH()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                connectToSSH()
            } else if newPhase == .background {
                appController.cleanup()
                sshClient.disconnect()
            }
        }
        .onDisappear {
            appController.cleanup()
            sshClient.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            connectToSSH()
        }
        .onReceive(appController.$currentVolume) { newVolume in
            self.volume = newVolume
        }
        .onDisappear {
            appController.cleanup()
            sshClient.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            appController.cleanup()
            sshClient.disconnect()
        }
        .tint(preferences.tintColorValue)
        .accentColor(preferences.tintColorValue)
    }
    
    private func connectToSSH() {
        // First cleanup existing connections
        appController.cleanup()
        sshClient.disconnect()
        
        connectionState = .connecting
        
        sshClient.connect(host: host, username: username, password: password) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.connectionState = .connected
                    self.appController.reset()
                    Task {
                        await self.appController.updateAllStates()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                        self.isReady = true
                    }
                case .failure(let error):
                    self.connectionState = .failed(error.localizedDescription)
                }
            }
        }
    }
    
    private func adjustVolume(by amount: Int) {
        let newVolume = min(max(Int(volume * 100) + amount, 0), 100)
        volume = Float(newVolume) / 100.0
        Task {
            await appController.setVolume(volume)
        }
    }
    
    private func debounceVolumeChange() {
        volumeChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task {
                await appController.setVolume(volume)
            }
        }
        volumeChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
}

struct ControlView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ControlView(
                host: "rwhitney-mac.local",
                displayName: "Ryan's Mac",
                username: "ryan",
                password: "",
                sshClient: SSHClient()
            )
        }
    }
}
