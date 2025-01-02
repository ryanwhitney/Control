import SwiftUI
import Combine

struct ControlView: View {
    @StateObject private var appController: AppController
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
            // Main content
            VStack {
                Spacer()
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
                    .padding(.horizontal)
                }
                .frame(height: 230)
                .tabViewStyle(.page)
                Spacer()
                
                // Volume Controls
                VStack(spacing: 20) {
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
                }
                .padding()
                Spacer()
            }
            .opacity(isReady && connectionState == .connected ? 1 : 0.3)
            .allowsHitTesting(connectionState == .connected)
            
            // Overlay states
            if connectionState.isOverlay {
                ProgressView("Connecting to \(host)...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
            } else if case .failed(let error) = connectionState {
                VStack {
                    Text("Connection Failed").font(.headline)
                    Text(error).foregroundColor(.red)
                    Button("Retry") {
                        connectToSSH()
                    }
                    .padding()
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(10)
            } else if case .disconnected = connectionState {
                VStack {
                    Text("Disconnected").font(.headline)
                    Button("Reconnect") {
                        connectToSSH()
                    }
                    .padding()
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(10)
            }
        }
        .navigationTitle(displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    appController.updateAllStates()
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
    }
    
    private func connectToSSH() {
        connectionState = .connecting
        
        sshClient.connect(host: host, username: username, password: password) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.connectionState = .connected
                    self.appController.updateAllStates()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
        appController.setVolume(volume)
    }
    
    private func debounceVolumeChange() {
        volumeChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            appController.setVolume(volume)
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
