import Foundation

struct IINAApp: AppPlatform {
    let id = "iina"
    let name = "IINA"
    
    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .previousTrack, icon: "backward.end.fill"),
            ActionConfig(action: .skipBackward(10), icon: "10.arrow.trianglehead.counterclockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(10), icon: "10.arrow.trianglehead.clockwise"),
            ActionConfig(action: .nextTrack, icon: "forward.end.fill")
        ]
    }
    
    func isRunningScript() -> String {
        """
        tell application "System Events" to set isAppOpen to exists (processes where name is "IINA")
        return isAppOpen as text
        """
    }
    
    private let statusScript = """
    tell application "System Events"
        set isRunning to exists (processes where name is "IINA")
        if not isRunning then
            return "Not running |||  |||  stopped  |||false"
        end if
        
        tell process "IINA"
            try
                -- Get the current window title which contains the media name
                set windowTitle to name of front window
                set AppleScript's text item delimiters to "  —  /"
                set cleanTitle to first text item of windowTitle
                set AppleScript's text item delimiters to ""
                
                -- Check if playing by looking at the play/pause menu item
                set isPlaying to false
                try
                    tell application "System Events"
                        tell process "IINA"
                            set playPauseMenu to menu item 1 of menu "Playback" of menu bar 1
                            set menuName to name of playPauseMenu
                            set isPlaying to (menuName contains "Pause")
                        end tell
                    end tell
                on error
                    set isPlaying to false
                end try
                
                return cleanTitle & "|||   ||| " & isPlaying & " ||| " & isPlaying
            on error
                return "Nothing playing |||   ||| false ||| false"
            end try
        end tell
    end tell
    """
    
    func fetchState() -> String {
        return statusScript
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
            error: nil
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return """
            tell application "IINA" to activate
            tell application "System Events"
                tell process "IINA"
                    key code 49 -- spacebar
                end tell
            end tell
            """
        case .skipBackward:
            return """
            tell application "IINA" to activate
            tell application "System Events"
                tell process "IINA"
                    key code 123 -- left arrow
                end tell
            end tell
            """
        case .skipForward:
            return """
            tell application "IINA" to activate
            tell application "System Events"
                tell process "IINA"
                    key code 124 -- right arrow
                end tell
            end tell
            """
        case .previousTrack:
            return """
            tell application "IINA" to activate
            tell application "System Events"
                tell process "IINA"
                    key code 123 using {command down} -- cmd+left
                end tell
            end tell
            """
        case .nextTrack:
            return """
            tell application "IINA" to activate
            tell application "System Events"
                tell process "IINA"
                    key code 124 using {command down} -- cmd+right
                end tell
            end tell
            """
            }
    }
}
