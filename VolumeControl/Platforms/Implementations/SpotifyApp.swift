import Foundation

struct SpotifyApp: AppPlatform {
    let id = "spotify"
    let name = "Spotify"
    
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
        tell application "System Events" to set isAppOpen to exists (processes where name is "Spotify")
        return isAppOpen as text
        """
    }
    
    private let statusScript = """
    tell application "Spotify"
        if not running then
            return "Spotify is not running|||stopped|||false"
        end if
        set trackName to name of current track
        set artistName to artist of current track
        set playerState to player state as text
        set isPlaying to player state is playing
        return trackName & "|||" & artistName & "|||" & playerState & "|||" & isPlaying
    end tell
    """
    
    func fetchState() -> String {
        return statusScript
    }
    
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
            subtitle: "Spotify is not running",
            isPlaying: nil,
            error: nil
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return """
            tell application "Spotify"
                playpause
            end tell
            """
        case .previousTrack:
            return """
            tell application "Spotify"
                previous track
            end tell
            """
        case .nextTrack:
            return """
            tell application "Spotify"
                next track
            end tell
            """
        default:
            return ""
        }
    }
}
