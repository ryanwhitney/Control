import Foundation

struct IINAApp: AppPlatform {
    let id = "iina"
    let name = "IINA"
    let defaultEnabled = false
    
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
            
            -- Try to get window title via System Events only
            set windowTitle to ""
            try
            tell process "IINA"
                if (count of windows) > 0 then
                    set windowTitle to name of front window
                end if
            end tell
            end try
            
            if windowTitle is "" then
                return "Nothing playing |||   ||| false ||| false"
            end if
            
            -- Check if window title indicates non-media windows
            set nonMediaWindows to {"Window", "Preferences", "Log Viewer", "Choose Media Files", "Playback History"}
            repeat with nonMediaWindow in nonMediaWindows
                if windowTitle is nonMediaWindow then
                    return "Nothing playing |||   ||| false ||| false"
                end if
            end repeat
            
            -- Try to parse title, fall back to full title if parsing fails
            set cleanTitle to windowTitle
            try
                set AppleScript's text item delimiters to "  —  /"
                set cleanTitle to first text item of windowTitle
                set AppleScript's text item delimiters to ""
            end try
            
            -- Now that we know media is loaded, check play/pause state
            set isPlaying to false
            try
                tell application "IINA" to activate
                tell process "IINA"
                    set playPauseMenu to menu item 1 of menu "Playback" of menu bar 1
                    set isPlaying to (name of playPauseMenu contains "Pause")
                end tell
            end try
            
            return cleanTitle & "|||   ||| " & isPlaying & " ||| " & isPlaying
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
