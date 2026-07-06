import Foundation

struct MusicApp: AppPlatform {
    let id = "music"
    let name = "Music"
    let defaultEnabled = true

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
        tell application "Music"
            \(actionScript)
            if player state is stopped then
                return "Nothing playing \(sep)    \(sep) false"
            end if
            set trackName to name of current track
            set artistName to artist of current track
            set playerState to player state as text
            set isPlaying to player state is playing
            return trackName & "\(sep)" & artistName & "\(sep)" & isPlaying
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    // Override the default helper to make use of the shared template so the
    // action and status execute inside the same `tell application` block.
    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(precededBy: actionScript(for: action))
    }

    /// AppleScript run *before* the status read, waiting for the app's state to
    /// settle so the read doesn't capture the pre-action value: track changes
    /// via `waitForTrackChangeScript`, play/pause via
    /// `waitForPlayStateChangeScript`. Both polls exit the instant the state
    /// updates, so a synchronous player pays no penalty.
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

    func parseState(_ output: String) -> AppState {
        parseSeparatedState(output)
            ?? AppState(title: "", subtitle: "", isPlaying: nil, error: "Error")
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
} 
