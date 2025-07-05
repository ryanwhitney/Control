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
    
    func isRunningScript() -> String {
        "tell application \"System Events\" to exists (processes where name is \"Music\")"
    }
    
    // Template status script that can optionally inject action AppleScript
    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "Music"
            \(actionLines)
            if player state is stopped then
                return "Nothing playing |||    ||| false"
            end if
            set trackName to name of current track
            set artistName to artist of current track
            set playerState to player state as text
            set isPlaying to player state is playing
            return trackName & "|||" & artistName & "|||" & isPlaying
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    // Override the default helper to make use of the shared template so the
    // action and status execute inside the same `tell application` block.
    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(actionLines: executeAction(action))
    }
    
    func parseState(_ output: String) -> AppState {
        let components = output.components(separatedBy: "|||")
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
            error: "Error"
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
} 
