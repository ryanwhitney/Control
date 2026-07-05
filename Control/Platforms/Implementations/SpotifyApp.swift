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

    /// AppleScript run *before* the status read. Both track changes and
    /// play/pause update Spotify's state a beat after the command returns, so
    /// each waits for the change (bounded poll) before the status is read:
    /// track changes via `waitForTrackChangeScript`, play/pause via
    /// `waitForPlayStateChangeScript`. Reading immediately would report the
    /// pre-action state.
    private func actionScript(for action: AppAction) -> String {
        switch action {
        case .nextTrack, .previousTrack:
            return waitForTrackChangeScript(around: executeAction(action))
        case .playPauseToggle:
            return waitForPlayStateChangeScript(around: executeAction(action))
        default:
            return executeAction(action)
        }
    }
}
