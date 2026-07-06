import Foundation

struct SpotifyApp: AppPlatform {
    let id = "spotify"
    let name = "Spotify"
    let defaultEnabled = false
    
    var supportedActions: [ActionConfig] {
        [.previousTrack, .playPause, .nextTrack]
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
                set isPlaying to player state is playing
                return trackName & "\(sep)" & artistName & "\(sep)" & isPlaying
            end try
            return "Nothing playing  \(sep)  \(sep)" & false
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

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

    /// AppleScript run *before* the status read. Spotify updates its state a
    /// beat after a command returns, so each action waits for the change before
    /// the status is read (see the waitFor… helpers in Types.swift).
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
