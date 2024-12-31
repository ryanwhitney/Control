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

    // Tracking playback states for each app
    @State private var isQuickTimePlaying: Bool = false
    @State private var isMusicPlaying: Bool = false
    @State private var isTVPlaying: Bool = false

    @State private var sshOutput: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var volumeChangeWorkItem: DispatchWorkItem?

    private let quickTimeScript = """
    tell application "QuickTime Player"
        if not (exists document 1) then
            return "No media loaded"
        end if
        set mediaName to name of document 1
        return mediaName
    end tell
    """

    private let musicScript = """
    tell application "Music"
        if player state is stopped then
            return "No track playing"
        end if
        set trackName to name of current track
        set artistName to artist of current track
        return trackName & " - " & artistName
    end tell
    """

    private let vlcScript = """
    tell application "VLC"
        if not playing then
            return "No media playing"
        end if
        set mediaName to name of current item
        return mediaName
    end tell
    """

    private let tvScript = """
    tell application "TV"
        if player state is stopped then
            return "No media playing"
        end if
        set mediaName to name of current track
        return mediaName
    end tell
    """

    // Add state variables for media info
    @State private var quickTimeInfo: String = "Checking..."
    @State private var musicInfo: String = "Checking..."
    @State private var vlcInfo: String = "Checking..."
    @State private var tvInfo: String = "Checking..."

    enum ConnectionState: Equatable {
        case connecting
        case connected
        case disconnected
        case failed(String)
        
        // Implement Equatable manually because of associated value
        static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.connecting, .connecting),
                 (.connected, .connected),
                 (.disconnected, .disconnected):
                return true
            case (.failed(let lhsError), .failed(let rhsError)):
                return lhsError == rhsError
            default:
                return false
            }
        }
    }

    var body: some View {
        VStack {
            switch connectionState {
            case .connecting:
                ProgressView("Connecting to \(host)...")

            case .connected:
                VStack {
                    Spacer()
                    TabView {
                        // MUSIC
                        VStack(spacing: 20) {
                            VStack(spacing: 4) {
                                Text("Music")
                                    .fontWeight(.bold)
                                    .fontWidth(.expanded)
                                Text(musicInfo)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            HStack(spacing: 20) {
                                Button("Previous track", systemImage: "arrowtriangle.backward.fill") {
                                    musicAction("backward")
                                }
                                .styledButton()

                                Button(action: {
                                    toggleMusicPlayPause()
                                }) {
                                    Image(systemName: isMusicPlaying ? "pause.fill" : "play.fill")
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
                            VStack(spacing: 4) {
                                Text("TV")
                                    .fontWeight(.bold)
                                    .fontWidth(.expanded)
                                Text(tvInfo)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            HStack(spacing: 20) {
                                Button("Back 5 seconds", systemImage: "5.arrow.trianglehead.counterclockwise") {
                                    tvAction("backward")
                                }
                                .styledButton()

                                Button(action: {
                                    toggleTVPlayPause()
                                }) {
                                    Image(systemName: isTVPlaying ? "pause.fill" : "play.fill")
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
                            VStack(spacing: 4) {
                                Text("VLC")
                                    .fontWeight(.bold)
                                    .fontWidth(.expanded)
                                Text(vlcInfo)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
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
                            VStack(spacing: 4) {
                                Text("QuickTime")
                                    .fontWeight(.bold)
                                    .fontWidth(.expanded)
                                Text(quickTimeInfo)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
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
                    .frame(height: 240)
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

                Spacer()
                VStack {
                    Text("Disconnected").font(.headline)
                    Button("Reconnect") {
                        connectAndRefresh()
                    }
                    .padding()
                    .onAppear {
                        connectAndRefresh()
                    }
                }

            case .failed(let error):

                Spacer()
                VStack {
                    Text("Connection Failed").font(.headline)
                    Text(error).foregroundColor(.red)
                    Button("Go Back") { dismiss() }.padding()
                }
            }

            Spacer()
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
            refreshMediaInfo()
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                print("App active, reconnecting...")
                connectToSSH()
                refreshMediaInfo()
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
                    refreshMediaStates()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Test Speaker", systemImage: "speaker.wave.2.bubble.fill") {
                    testCommand()
                }
            }
        }
    }

    // MARK: - Connection & Refresh
    private func connectAndRefresh() {
        connectToSSH()
        refreshMediaStates()
    }

    /// Refresh all relevant media states at once
    private func refreshMediaStates() {
        getVolume()
        fetchQuickTimeState()
        fetchMusicState()
        fetchTVState()
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
                    // Once connected, fetch initial states
                    self.refreshMediaStates()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.isReady = true
                    }
                }
            }
        }
    }

    // MARK: - Volume

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

    // MARK: - QuickTime

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
        // Immediately toggle local state
        isQuickTimePlaying.toggle()
        quickTimeAction("togglePlayPause")

        // Re-fetch state after a delay (to stay in sync)
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

    // MARK: - Music

    /// Fetch whether Music is playing/paused/stopped
    private func fetchMusicState() {
        let script = """
            tell application "Music"
                if player state is stopped then return "stopped"
                if player state is playing then
                    return "playing"
                else
                    return "paused"
                end if
            end tell
        """
        let command = "/usr/bin/osascript -e '\(script)'"
        executeCommand(command) { output in
            DispatchQueue.main.async {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.isMusicPlaying = (trimmed == "playing")
            }
        }
    }

    /// Toggle Music playback while keeping local `isMusicPlaying` in sync
    private func toggleMusicPlayPause() {
        // Optimistically toggle local state
        isMusicPlaying.toggle()
        musicAction("togglePlayPause")

        // Re-check the actual state a moment later
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            fetchMusicState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            fetchMusicState()
        }
    }

    private func musicAction(_ action: String) {
        let script: String
        switch action {
        case "backward":
            // "Previous track" in Music
            script = """
            tell application "Music"
                previous track
            end tell
            """
        case "forward":
            // "Next track" in Music
            script = """
            tell application "Music"
                next track
            end tell
            """
        case "togglePlayPause":
            // Toggle play/pause based on current state
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

    // MARK: - TV

    /// Fetch whether TV is playing/paused/stopped
    private func fetchTVState() {
        let script = """
            tell application "TV"
                if player state is stopped then return "stopped"
                if player state is playing then
                    return "playing"
                else
                    return "paused"
                end if
            end tell
        """
        let command = "/usr/bin/osascript -e '\(script)'"
        executeCommand(command) { output in
            DispatchQueue.main.async {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.isTVPlaying = (trimmed == "playing")
            }
        }
    }

    /// Toggle TV playback while keeping local `isTVPlaying` in sync
    private func toggleTVPlayPause() {
        // Optimistically toggle local state
        isTVPlaying.toggle()
        tvAction("togglePlayPause")

        // Re-check the actual state a moment later
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            fetchTVState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            fetchTVState()
        }
    }

    private func tvAction(_ action: String) {
        let script: String
        switch action {
        case "backward":
            script = """
            tell application "TV"
                if player state is stopped then return
                set currentPos to player position
                set newPos to currentPos - 5
                if newPos < 0 then set newPos to 0
                set player position to newPos
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
                if player state is stopped then
                    play
                else if player state is playing then
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

    // MARK: - VLC

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
            // VLC doesn’t expose “playing” or “paused” easily via AppleScript
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

    // MARK: - Misc

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
                    self.errorMessage = nil  // Clear error on success
                    self.appendOutput(output)
                    completion?(output)
                }
            }
        }
    }

    private func appendOutput(_ text: String) {
        sshOutput = "\(text)\n" + sshOutput
    }

    // Add function to refresh media info
    private func refreshMediaInfo() {
        executeCommand("osascript -e '\(quickTimeScript)'") { output in
            self.quickTimeInfo = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        executeCommand("osascript -e '\(musicScript)'") { output in
            self.musicInfo = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        executeCommand("osascript -e '\(vlcScript)'") { output in
            self.vlcInfo = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        executeCommand("osascript -e '\(tvScript)'") { output in
            self.tvInfo = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // Add periodic refresh of media info
    private func startMediaInfoRefresh() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            if self.connectionState == .connected {
                self.refreshMediaInfo()
            }
        }
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
