import SwiftUI

struct ControlView: View {
    let host: String
    let displayName: String
    let username: String
    let password: String
    let sshClient: SSHClient

    @State private var volume: Float = 0.5
    @State private var errorMessage: String?
    @State private var connectionState: ConnectionState = .connecting
    @State private var isReady: Bool = false
    @State private var isQuickTimePlaying: Bool = false
    @State private var sshOutput: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var volumeChangeWorkItem: DispatchWorkItem?

    enum ConnectionState {
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    var body: some View {
        VStack {
            switch connectionState {
            case .connecting:
                ProgressView("Connecting to \(host)...")

            case .connected:
                VStack{
                    Spacer()
                    TabView {
                        // TV
                        VStack(spacing: 20) {
                            Text("Music")
                                .fontWeight(.bold)
                                .fontWidth(.expanded)
                            HStack(spacing: 20) {
                                Button("Previous track", systemImage: "arrowtriangle.backward.fill") {
                                    musicAction("backward")
                                }
                                .styledButton()

                                Button(action: {
                                    musicAction("togglePlayPause")
                                }) {
                                    Image(systemName: "playpause.fill")
                                }
                                .styledButton()

                                Button("Next track", systemImage: "arrowtriangle.forward.fill") {
                                    musicAction("forward")
                                }
                                .styledButton()
                            }
                        }
                        // TV
                        VStack(spacing: 20) {
                            Text("TV")
                                .fontWeight(.bold)
                                .fontWidth(.expanded)
                            HStack(spacing: 20) {
                                Button("Back 5 seconds", systemImage: "5.arrow.trianglehead.counterclockwise") {
                                    tvAction("backward")
                                }
                                .styledButton()

                                Button(action: {
                                    tvAction("togglePlayPause")
                                }) {
                                    Image(systemName: "playpause.fill")
                                }
                                .styledButton()

                                Button("Forward 5 seconds", systemImage: "5.arrow.trianglehead.clockwise") {
                                    tvAction("forward")
                                }
                                .styledButton()
                            }
                        }
                        // VLC
                        VStack(spacing: 20) {
                            Text("VLC")
                                .fontWeight(.bold)
                                .fontWidth(.expanded)
                            HStack(spacing: 20) {
                                Button("Back 10 seconds", systemImage: "10.arrow.trianglehead.counterclockwise") {
                                    vlcAction("backward")
                                }
                                .styledButton()

                                Button(action: {
                                    vlcAction("togglePlayPause")
                                }) {
                                    Image(systemName: "playpause.fill")
                                }
                                .styledButton()

                                Button("Forward 10 seconds", systemImage: "10.arrow.trianglehead.clockwise") {
                                    vlcAction("forward")
                                }
                                .styledButton()
                            }
                        }
                        // QUICKTIME
                        VStack(spacing: 20) {
                            Text("QuickTime")
                                .fontWeight(.bold)
                                .fontWidth(.expanded)
                            HStack(spacing: 20) {
                                Button("Back 5 seconds", systemImage: "5.arrow.trianglehead.counterclockwise") {
                                    quickTimeAction("backward")
                                }
                                .styledButton()

                                Button(action: {
                                    toggleQuickTimePlayPause()
                                }) {
                                    Image(systemName: isQuickTimePlaying ? "pause.fill" : "play.fill")
                                }
                                .styledButton()

                                Button("Forward 5 seconds", systemImage: "5.arrow.trianglehead.clockwise") {
                                    quickTimeAction("forward")
                                }
                                .styledButton()
                            }
                        }
                    }
                    .frame(height: 300)
                    .tabViewStyle(.page)

                    Spacer()
                    // VOLUME
                    VStack(spacing: 20) {
                        Text("Volume: \(Int(volume * 100))%")
                            .fontWeight(.bold)
                            .fontWidth(.expanded)
                        Slider(value: $volume, in: 0...1, step: 0.01)
                            .padding(.horizontal)
                            .onAppear {
                                getVolume()
                            }
                            .onChange(of: volume) {
                                debounceVolumeChange()
                            }
                        HStack(spacing: 20) {
                            Button("-5") { adjustVolume(by: -5) }.styledButton()
                            Button("-1") { adjustVolume(by: -1) }.styledButton()
                            Button("+1") { adjustVolume(by: 1) }.styledButton()
                            Button("+5") { adjustVolume(by: 5) }.styledButton()
                        }
                    }
                    Spacer()
                }
                .opacity(isReady ? 1 : 0)
                .animation(.easeInOut(duration: 0.5), value: isReady)

            case .disconnected:
                VStack {
                    Text("Disconnected").font(.headline)
                    Button("Reconnect") {
                        connectAndRefresh()
                    }
                    .padding()
                    .onAppear{
                        connectAndRefresh()
                    }
                }

            case .failed(let error):
                VStack {
                    Text("Connection Failed").font(.headline)
                    Text(error).foregroundColor(.red)
                    Button("Go Back") { dismiss() }.padding()
                }
            }
//
//            if let error = errorMessage {
//                Text(error).foregroundColor(.red).padding()
//            }
        }
        .padding()
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(displayName)
                    .font(.subheadline)
                    .accessibilityAddTraits(.isHeader)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            connectAndRefresh()
        }
        .onChange(of: scenePhase) { newPhase, oldPhase in
            print("Old phase: \(String(describing: oldPhase))")
            print("New phase: \(newPhase)")

            switch newPhase {
            case .active:
                print("App active, reconnecting...")
                connectAndRefresh()
            case .background:
                print("App backgrounded, disconnecting...")
                sshClient.disconnect()
                connectionState = .disconnected
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    refreshQuickTimeState()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Test Speaker", systemImage: "speaker.wave.2.bubble.fill") {
                    testCommand()
                }
            }
        }
    }

    private func connectAndRefresh() {
        connectToSSH()
        refreshQuickTimeState()
    }

    private func connectToSSH() {
        isReady = false
        connectionState = .connecting
        
        sshClient.connect(host: host, username: username, password: password) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.connectionState = .failed(error.localizedDescription)
                    self.appendOutput("Connection failed: \(error.localizedDescription)")
                case .success:
                    self.connectionState = .connected
                    self.appendOutput("Connected successfully")
                    refreshQuickTimeState()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.isReady = true
                    }
                }
            }
        }
    }

    private func getVolume() {
        let command = "/usr/bin/osascript -e 'get volume settings'"
        executeCommand(command) { output in
            if let volumeStr = output.split(separator: ",").first,
               let volumeNum = volumeStr.split(separator: ":").last,
               let volumeLevel = Float(volumeNum.trimmingCharacters(in: .whitespaces)) {
                self.volume = volumeLevel / 100.0
            } else {
                self.errorMessage = "Invalid volume format: \(output)"
            }
        }
    }

    private func setVolume() {
        let volumeInt = Int(volume * 100)
        let command = "/usr/bin/osascript -e 'set volume output volume \(volumeInt)'"
        executeCommand(command)
    }

    private func adjustVolume(by amount: Int) {
        let newVolume = min(max(Int(volume * 100) + amount, 0), 100)
        volume = Float(newVolume) / 100.0
        setVolume()
    }

    private func debounceVolumeChange() {
        volumeChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            setVolume()
        }
        volumeChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func fetchQuickTimeState(completion: (() -> Void)? = nil) {
        let script = """
            tell application "QuickTime Player"
                if not (exists document 1) then return "no-document"
                set theDocument to document 1
                if playing of theDocument then
                    return "playing"
                else
                    return "paused"
                end if
            end tell
        """
        let command = "/usr/bin/osascript -e '\(script)'"
        executeCommand(command) { output in
            DispatchQueue.main.async {
                self.isQuickTimePlaying = (output.trimmingCharacters(in: .whitespacesAndNewlines) == "playing")
                completion?()
            }
        }
    }

    private func toggleQuickTimePlayPause() {
        isQuickTimePlaying.toggle()
        quickTimeAction("togglePlayPause")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            fetchQuickTimeState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            fetchQuickTimeState()
        }
    }

    private func refreshQuickTimeState() {
        getVolume()
        fetchQuickTimeState()
    }

    private func musicAction(_ action: String) {
        let script: String
        switch action {
        case "backward":
            script = """
            tell application "Music"
                previous track
            end tell
            """
        case "forward":
            script = """
            tell application "Music"
                next track
            end tell
            """
        case "togglePlayPause":
            script = """
            tell application "Music"
                if player state is stopped then return
                if player state is playing then
                    pause
                else
                    play
                end if
            end tell
            
            """
        default:
            return
        }
        let command = "osascript -e '\(script)'"
        executeCommand(command)
    }
    private func tvAction(_ action: String) {
        let script: String
        switch action {
        case "backward":
            script = """
            tell application "TV"
                if player state is stopped then return
                set currentPos to the player position
                set newPos to currentPos - 5
                if newPos < 0 then set newPos to 0
                set the player position to newPos
            end tell
            """
        case "forward":
            script = """
            tell application "TV"
                if player state is stopped then return
                set currentPos to player position
                set newPos to currentPos + 5
                set player position to newPos
                end tell
            """
        case "togglePlayPause":
            script = """
            tell application "TV"
                if player state is stopped then return
                if player state is playing then
                    pause
                else
                    play
                end if
            end tell
            
            """
        default:
            return
        }
        let command = "osascript -e '\(script)'"
        executeCommand(command)
    }

    private func vlcAction(_ action: String) {
        let script: String
        switch action {
        case "backward":
            script = """
            tell application "VLC"
                step backward
            end tell
            """
        case "forward":
            script = """
            tell application "VLC"
                step forward
            end tell
            """
        case "togglePlayPause":
            script = """
            tell application "VLC"
                play 
            end tell
            """
        default:
            return
        }
        let command = "osascript -e '\(script)'"
        executeCommand(command)
    }

    private func quickTimeAction(_ action: String) {
        let script: String
        switch action {
        case "backward":
            script = """
            tell application "QuickTime Player"
                if not (exists document 1) then return
                set theDocument to document 1
                set currentTime to current time of theDocument
                set newTime to currentTime - 5
                if newTime < 0 then set newTime to 0
                set current time of theDocument to newTime
            end tell
            """
        case "forward":
            script = """
            tell application "QuickTime Player"
                if not (exists document 1) then return
                set theDocument to document 1
                set currentTime to current time of theDocument
                set videoDuration to duration of theDocument
                set newTime to currentTime + 5
                if newTime > videoDuration then set newTime to videoDuration - 0.01
                set current time of theDocument to newTime
            end tell
            """
        case "togglePlayPause":
            script = """
            tell application "QuickTime Player"
                if not (exists document 1) then return
                set theDocument to document 1
                if playing of theDocument then
                    pause theDocument
                else
                    play theDocument
                end if
            end tell
            """
        default:
            return
        }
        let command = "osascript -e '\(script)'"
        executeCommand(command)
    }

    private func testCommand() {
        let command = "say 'hello ryan'"
        executeCommand(command)
    }

    private func executeCommand(_ command: String, completion: ((String) -> Void)? = nil) {
        appendOutput("$ \(command)")
        sshClient.executeCommandWithNewChannel(command) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.errorMessage = "Error: \(error.localizedDescription)"
                case .success(let output):
                    self.errorMessage = nil  // Clear error message on success
                    self.appendOutput(output)
                    completion?(output)
                }
            }
        }
    }

    private func appendOutput(_ text: String) {
        sshOutput = "\(text)\n" + sshOutput
    }
}

private extension Button {
    func styledButton() -> some View {
        self.padding(12)
            .frame(width: 60, height: 60)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .labelStyle(.iconOnly)
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
