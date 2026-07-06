import Foundation

struct TVApp: AppPlatform {
    let id = "tv"
    let name = "TV"
    let defaultEnabled = true
    // TV's skip actions are key-code driven and can overload the channel when
    // tapped rapidly; AppController spaces actions by this much.
    let minActionInterval: TimeInterval = 0.3

    var supportedActions: [ActionConfig] {
        [.skipBackward(10), .playPause, .skipForward(10)]
    }


    private func statusScript(precededBy actionScript: String = "") -> String {
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "TV"
            \(actionScript)
            set rawState to player state as text
            if rawState is "stopped" then
                return "Nothing playing\(sep)   \(sep)false"
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
                return "Nothing playing\(sep)   \(sep)false"
            end if

            set isPlaying to (rawState is "playing")
            return trackName & "\(sep)   \(sep)" & isPlaying
        end tell
        """
    }
    
    func fetchState() -> String { statusScript() }
    
    func actionWithStatus(_ action: AppAction) -> String {
        switch action {
        case .skipBackward, .skipForward:
            // These actions are self-contained System Events scripts, so run them
            // before the status read rather than injecting inside its tell block.
            return executeAction(action) + "\n" + fetchState()
        default:
            return statusScript(precededBy: executeAction(action))
        }
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return "playpause"
        case .skipBackward:
            return """
            tell application "System Events"
                if frontmost of application "TV" is false then
                    tell application "TV" to activate
                    delay 0.1
                end if
                tell process "TV" to key code 123
            end tell
            """
        case .skipForward:
            return """
            tell application "System Events"
                if frontmost of application "TV" is false then
                    tell application "TV" to activate
                    delay 0.1
                end if
                tell process "TV" to key code 124
            end tell
            """
        default:
            return ""
        }
    }
} 
