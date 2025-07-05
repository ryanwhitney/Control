import Foundation

struct TVApp: AppPlatform {
    let id = "tv"
    let name = "TV"
    let defaultEnabled = true

    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .skipBackward(10), icon: "10.arrow.trianglehead.counterclockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(10), icon: "10.arrow.trianglehead.clockwise")
        ]
    }
    
    func isRunningScript() -> String {
        "tell application \"System Events\" to exists (processes where name is \"TV\")"
    }
    
    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "TV"
            \(actionLines)
            try
                set rawState to player state as text
                if rawState is "stopped" then
                    return "Nothing playing|||   |||stopped|||false"
                end if
                
                set trackName to ""
                try
                    set trackName to name of current track
                end try
                
                -- If no track name, try window for streaming content
                if trackName is "" then
                    try
                        set windowName to name of front window
                        if windowName is not "TV" then
                            set trackName to windowName
                        end if
                    end try
                end if
                
                if trackName is "" then
                    return "Nothing playing|||   |||stopped|||false"
                end if
                
                set isPlaying to (rawState is "playing")
                return trackName & "|||   |||" & rawState & "|||" & isPlaying
            on error errMsg
                return "Error|||   |||error|||false"
            end try
        end tell
        """
    }
    
    func fetchState() -> String { statusScript() }
    
    func actionWithStatus(_ action: AppAction) -> String {
        switch action {
        case .skipBackward, .skipForward:
            // For complex actions, chain the self-contained script with the status script.
            // The final return value will be from fetchState().
            return executeAction(action) + "\n" + fetchState()
        default:
            // For simple actions, inject them into the status script as before.
            return statusScript(actionLines: executeAction(action))
        }
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
            subtitle: "",
            isPlaying: nil,
            error: "Failed to parse TV state"
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return "playpause"
        case .skipBackward:
            return """
            tell application "TV" to activate
            delay 0.1
            try
                tell application "TV" to set player position to ((get player position) - 10)
            on error
                tell application "System Events" to tell process "TV" to key code 123
            end try
            """
        case .skipForward:
            return """
            tell application "TV" to activate
            delay 0.1
            try
                tell application "TV" to set player position to ((get player position) + 10)
            on error
                tell application "System Events" to tell process "TV" to key code 124
            end try
            """
        default:
            return ""
        }
    }
} 
