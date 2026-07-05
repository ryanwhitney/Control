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
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "Spotify"
            \(actionScript)
            if not running then
                return "Not running \(sep)  \(sep)false"
            end if
            try
                set trackName to name of current track
                set artistName to artist of current track
                set playerState to player state as text
                set isPlaying to player state is playing
                return trackName & "\(sep)" & artistName & "\(sep)" & isPlaying
            end try
            return "Nothing playing  \(sep)  \(sep)" & false
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func parseState(_ output: String) -> AppState {
        parseSeparatedState(output)
            ?? AppState(title: "", subtitle: "", isPlaying: nil, error: nil)
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

    /// AppleScript run *before* the status read. Track changes go through the
    /// shared wait-for-track-change poll (see `waitForTrackChangeScript`) —
    /// Spotify's new track often loads from the network, so a fixed delay
    /// could read mid-transition and momentarily fall into "Nothing playing".
    /// Play/pause changes player state rather than the track and reads
    /// immediately (matching Music).
    private func actionScript(for action: AppAction) -> String {
        switch action {
        case .nextTrack, .previousTrack:
            return waitForTrackChangeScript(around: executeAction(action))
        default:
            return executeAction(action)
        }
    }
}
