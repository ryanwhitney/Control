import Foundation

struct MPVApp: AppPlatform {
    let id = "mpv"
    let name = "mpv"
    let defaultEnabled = false

    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .previousTrack, icon: "backward.end.fill"),
            ActionConfig(action: .skipBackward(5), icon: "5.arrow.trianglehead.counterclockwise"),
            // Static play/pause glyph: mpv doesn't expose reliable play/pause
            // state over AppleScript, so a dynamic icon would misrepresent it.
            ActionConfig(action: .playPauseToggle, icon: "playpause.fill"),
            ActionConfig(action: .skipForward(5), icon: "5.arrow.trianglehead.clockwise"),
            ActionConfig(action: .nextTrack, icon: "forward.end.fill")
        ]
    }

    func isRunningScript() -> String {
        """
        tell application "System Events" to set isAppOpen to exists (processes where name is "mpv")
        return isAppOpen as text
        """
    }

    func isInstalledScript() -> String {
        // mpv can be installed via Homebrew or as an app bundle
        """
        tell application "System Events"
            -- Check for app bundle
            if exists disk item "/Applications/mpv.app" then
                return "true"
            end if
            -- Check for Homebrew installation
            try
                do shell script "which mpv"
                return "true"
            on error
                return "false"
            end try
        end tell
        """
    }

    private let statusScript = """
        tell application "System Events"
            set isRunning to exists (processes where name is "mpv")
            if not isRunning then
                return "Not running |||  ||| stopped ||| false"
            end if

            -- Try to get window title via System Events
            set windowTitle to ""
            try
                tell process "mpv"
                    if (count of windows) > 0 then
                        set windowTitle to name of front window
                    end if
                end tell
            end try

            if windowTitle is "" then
                return "Nothing playing |||  ||| false ||| false"
            end if

            -- mpv window titles are typically just the filename
            -- Clean up common extensions and path info
            set cleanTitle to windowTitle

            -- Check if paused (mpv adds " - paused" to window title when paused)
            set isPlaying to true
            if cleanTitle ends with " - paused" then
                set isPlaying to false
                set cleanTitle to text 1 thru -10 of cleanTitle
            end if

            -- Also check for " - mpv" suffix and remove it
            if cleanTitle ends with " - mpv" then
                set cleanTitle to text 1 thru -7 of cleanTitle
            end if

            return cleanTitle & "|||  ||| " & isPlaying & " ||| " & isPlaying
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
        // System Events `key code` is delivered to the frontmost app regardless of
        // the enclosing `tell process`, so mpv must be brought frontmost first or
        // the keystroke lands on whatever app the user currently has in front.
        switch action {
        case .playPauseToggle:
            return """
            tell application "System Events"
                set frontmost of process "mpv" to true
                tell process "mpv"
                    key code 49 -- spacebar
                end tell
            end tell
            """
        case .skipBackward:
            return """
            tell application "System Events"
                set frontmost of process "mpv" to true
                tell process "mpv"
                    key code 123 -- left arrow
                end tell
            end tell
            """
        case .skipForward:
            return """
            tell application "System Events"
                set frontmost of process "mpv" to true
                tell process "mpv"
                    key code 124 -- right arrow
                end tell
            end tell
            """
        case .previousTrack:
            return """
            tell application "System Events"
                set frontmost of process "mpv" to true
                tell process "mpv"
                    key code 43 using {shift down} -- < (shift+comma) for previous
                end tell
            end tell
            """
        case .nextTrack:
            return """
            tell application "System Events"
                set frontmost of process "mpv" to true
                tell process "mpv"
                    key code 47 using {shift down} -- > (shift+period) for next
                end tell
            end tell
            """
        }
    }
}
