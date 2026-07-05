import Foundation

struct SpotifyApp: AppPlatform {
    let id = "spotify"
    let name = "Spotify"
    let defaultEnabled = false
    
    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .previousTrack, icon: "backward.end.fill"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .nextTrack, icon: "forward.end.fill")
        ]
    }
    
    func isRunningScript() -> String {
        """
        tell application "System Events"
            if exists (processes where name is "Spotify") then
                return "true"
            else
                return "false"
            end if
        end tell
        """
    }
    
    // Template status script that can optionally run action AppleScript first.
    private func statusScript(precededBy actionScript: String = "") -> String {
        """
        tell application "Spotify"
            \(actionScript)
            if not running then
                return "Not running ~|VCF|~  ~|VCF|~false"
            end if
            try
                set trackName to name of current track
                set artistName to artist of current track
                set playerState to player state as text
                set isPlaying to player state is playing
                return trackName & "~|VCF|~" & artistName & "~|VCF|~" & isPlaying
            end try
            return "Nothing playing  ~|VCF|~  ~|VCF|~" & false
        end tell
        """
    }
    
    func fetchState() -> String { statusScript() }
    
    func parseState(_ output: String) -> AppState {
        let components = output.components(separatedBy: "~|VCF|~")
        if components.count >= 3 {
            return AppState(
                title: components[0].trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: components[1].trimmingCharacters(in: .whitespacesAndNewlines),
                isPlaying: components[2].trimmingCharacters(in: .whitespacesAndNewlines) == "true",
                error: nil
            )
        }
        return AppState(
            title: "",
            subtitle: "",
            isPlaying: nil,
            error: nil
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return "playpause"
        case .previousTrack:
            return "previous track"
        case .nextTrack:
            return "next track"
        default:
            return ""
        }
    }
    
    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(precededBy: actionScript(for: action))
    }

    /// AppleScript run *before* the status read. Like Music, Spotify's
    /// `next track` / `previous track` return before `current track` settles —
    /// and the new track often loads from the network, so a fixed delay can read
    /// mid-transition and momentarily fall into the "Nothing playing" fallback.
    /// For those, poll until the track id (a URI) changes or playback stops, so
    /// the read reflects the settled track. Play/pause changes player state rather
    /// than the track and reads immediately (matching Music) — pending live
    /// testing that Spotify's `player state` updates fast enough without a delay.
    private func actionScript(for action: AppAction) -> String {
        switch action {
        case .nextTrack, .previousTrack:
            return """
            set previousTrackId to missing value
            try
                set previousTrackId to id of current track
            end try
            \(executeAction(action))
            repeat 20 times
                try
                    if player state is stopped then exit repeat
                    if id of current track is not previousTrackId then exit repeat
                end try
                delay 0.05
            end repeat
            """
        default:
            return executeAction(action)
        }
    }
}
