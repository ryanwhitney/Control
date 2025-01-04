import SwiftUI
import Combine

struct ControlView: View {
    @StateObject private var appController: AppController
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    let host: String
    let displayName: String
    let username: String
    let password: String
    let sshClient: SSHClient
    
    @State private var volume: Float = 0.5
    @State private var errorMessage: String?
    @State private var volumeChangeWorkItem: DispatchWorkItem?
    @State private var isReady: Bool = false
    @State private var connectionState: ConnectionState = .connecting
    @State private var screenBrightness: CGFloat = UIScreen.main.brightness
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
    
    init(host: String, displayName: String, username: String, password: String, sshClient: SSHClient) {
        self.host = host
        self.displayName = displayName
        self.username = username
        self.password = password
        self.sshClient = sshClient
        _appController = StateObject(wrappedValue: AppController(sshClient: sshClient))
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
                                AppControl(
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
                        HStack(spacing: 20) {
                            Button {
                                adjustVolume(by: -5)
                            } label: {
                                Text("-5")
                            }
                            .buttonStyle(CircularButtonStyle())

                            Button {
                                adjustVolume(by: -1)
                            } label: {
                                Text("-1")
                            }
                            .buttonStyle(CircularButtonStyle())

                            Button {
                                adjustVolume(by: 1)
                            } label: {
                                Text("+1")
                            }
                            .buttonStyle(CircularButtonStyle())

                            Button {
                                adjustVolume(by: 5)
                            } label: {
                                Text("+5")
                            }
                            .buttonStyle(CircularButtonStyle())
                        }
                        Spacer()
                    }
                    .frame(height: volumeHeight, alignment: .center)

                }
                .frame(width: geometry.size.width, height: totalHeight)
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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            connectToSSH()
        }
        .onReceive(appController.$currentVolume) { newVolume in
            self.volume = newVolume
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { _ in
            screenBrightness = UIScreen.main.brightness
        }
        .environment(\.screenBrightness, screenBrightness)
        .tint(preferences.tintColorValue)
        .accentColor(preferences.tintColorValue)
        .onDisappear {
            appController.cleanup()
            sshClient.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            appController.cleanup()
            sshClient.disconnect()
        }
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
                    // Reset AppController's active state
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
