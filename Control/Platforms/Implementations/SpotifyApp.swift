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
    
    // Template status script that can optionally inject action AppleScript
    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "Spotify"
            \(actionLines)
            if not running then
                return "Not running |||  |||stopped|||false"
            end if
            try
                set trackName to name of current track
                set artistName to artist of current track
                set playerState to player state as text
                set isPlaying to player state is playing
                return trackName & "|||" & artistName & "|||" & playerState & "|||" & isPlaying
            end try
            return "Nothing playing  |||  |||" & false & "|||" & false
        end tell
        """
    }
    
    func fetchState() -> String { statusScript() }
    
    func parseState(_ output: String) -> AppState {
        let components = output.components(separatedBy: "|||")
        if components.count >= 4 {
            return AppState(
                title: components[0].trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: components[1].trimmingCharacters(in: .whitespacesAndNewlines),
                isPlaying: components[3].trimmingCharacters(in: .whitespacesAndNewlines) == "true",
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
        // Add delay for all actions to let Spotify update its state
        let delayScript = "delay 0.3\n"
        
        return statusScript(actionLines: executeAction(action) + "\n" + delayScript)
    }
}
