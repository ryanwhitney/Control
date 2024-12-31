import SwiftUI

struct ControlView: View {
    @StateObject private var mediaController: MediaController
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
    
    enum ConnectionState {
        case connecting
        case connected
        case disconnected
        case failed(String)
    }
    
    init(host: String, displayName: String, username: String, password: String, sshClient: SSHClient) {
        self.host = host
        self.displayName = displayName
        self.username = username
        self.password = password
        self.sshClient = sshClient
        _mediaController = StateObject(wrappedValue: MediaController(sshClient: sshClient))
    }
    
    var body: some View {
        VStack {
            switch connectionState {
            case .connecting:
                ProgressView("Connecting to \(host)...")
                
            case .connected:
                VStack {
                        TabView{
                            ForEach(mediaController.platforms, id: \.id) { platform in
                                MediaControl(
                                    platform: platform,
                                    state: Binding(
                                        get: { mediaController.states[platform.id] ?? MediaState(title: "Error") },
                                        set: { mediaController.states[platform.id] = $0 }
                                    ),
                                    onAction: { action in
                                        mediaController.executeAction(platform: platform, action: action)
                                    }
                                )
                                .environmentObject(mediaController)
                                .frame(width: 300)

                        }

                        .padding()
                    }
                    .tabViewStyle(.page)
                    Spacer()
                    
                    // Volume Controls
                    VStack(spacing: 20) {
                        Text("Volume: \(Int(volume * 100))%")
                            .fontWeight(.bold)
                            .fontWidth(.expanded)
                        
                        Slider(value: $volume, in: 0...1, step: 0.01)
                            .padding(.horizontal)
                            .onChange(of: volume) { _ in
                                debounceVolumeChange()
                            }
                        
                        HStack(spacing: 20) {
                            Button("-5") { adjustVolume(by: -5) }.styledButton()
                            Button("-1") { adjustVolume(by: -1) }.styledButton()
                            Button("+1") { adjustVolume(by: 1) }.styledButton()
                            Button("+5") { adjustVolume(by: 5) }.styledButton()
                        }
                    }
                    .padding()
                }
                .opacity(isReady ? 1 : 0)
                .animation(.easeInOut(duration: 0.5), value: isReady)
                
            case .disconnected:
                VStack {
                    Text("Disconnected").font(.headline)
                    Button("Reconnect") {
                        connectToSSH()
                    }
                    .padding()
                }
                
            case .failed(let error):
                VStack {
                    Text("Connection Failed").font(.headline)
                    Text(error).foregroundColor(.red)
                }
            }
        }
        .navigationTitle(displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    mediaController.updateAllStates()
                }
            }
        }
        .onAppear {
            connectToSSH()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                connectToSSH()
            }
        }
    }
    
    private func connectToSSH() {
        isReady = false
        connectionState = .connecting
        
        sshClient.connect(host: host, username: username, password: password) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.connectionState = .connected
                    self.mediaController.updateAllStates()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
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
        mediaController.setVolume(volume)
    }
    
    private func debounceVolumeChange() {
        volumeChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            mediaController.setVolume(volume)
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
