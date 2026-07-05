import Foundation

struct MPVApp: AppPlatform {
    let id = "mpv"
    let name = "mpv"
    let defaultEnabled = false
    // Status uses System Events (title read; actions foreground the app), so it's
    // kept out of the global sweep and refreshed only when its tab is on screen.
    let checksStatusOnlyWhenVisible = true

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
            if exists disk item "/Applications/mpv.app" then
                return "true"
            end if
            try
                do shell script "which mpv"
                return "true"
            on error
                return "false"
            end try
        end tell
        """
    }

    // mpv has no AppleScript dictionary, so everything goes through System Events.
    // Status reads the window title (no focus needed), so we only bring mpv
    // frontmost when there's an action to deliver — keystrokes go to the frontmost
    // app regardless of the enclosing `tell process`. Poll-only status never
    // steals focus.
    private func statusScript(precededBy actionScript: String = "") -> String {
        """
        tell application "System Events"
            if (count of (processes where name is "mpv")) = 0 then
                return "Not running~|VCF|~   ~|VCF|~false"
            end if
            set previousFrontmostApp to null
            set shouldRestoreOrder to false
            if "\(actionScript)" is not "" then
                if not (frontmost of process "mpv") then
                    set previousFrontmostApp to name of first application process whose frontmost is true
                    set frontmost of process "mpv" to true
                    delay 0.1
                    set shouldRestoreOrder to true
                end if
            end if
            set resultString to "Nothing playing~|VCF|~   ~|VCF|~false"
            tell process "mpv"
                if "\(actionScript)" is not "" then
                    \(actionScript)
                end if
                if (count of windows) > 0 then
                    set windowTitle to name of front window
                    -- mpv appends " - paused" to the title when paused, " - mpv" otherwise.
                    set isPlaying to true
                    set cleanTitle to windowTitle
                    if cleanTitle ends with " - paused" then
                        set isPlaying to false
                        set cleanTitle to text 1 thru -10 of cleanTitle
                    end if
                    if cleanTitle ends with " - mpv" then
                        set cleanTitle to text 1 thru -7 of cleanTitle
                    end if
                    set resultString to cleanTitle & "~|VCF|~   ~|VCF|~" & isPlaying
                end if
            end tell
            if shouldRestoreOrder and previousFrontmostApp is not null then
                set frontmost of process previousFrontmostApp to true
            end if
            return resultString
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(precededBy: executeAction(action))
    }

    func parseState(_ output: String) -> AppState {
        let components = output.components(separatedBy: "~|VCF|~")
        if components.count >= 3 {
            return AppState(
                title: components[0].trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: components[1].trimmingCharacters(in: .whitespacesAndNewlines),
                isPlaying: components[2].trimmingCharacters(in: .whitespacesAndNewlines) == "true",
                error: nil
            )
        }
        return AppState(title: "", subtitle: "", isPlaying: nil, error: nil)
    }

    // Returns just the key line(s), injected inside `tell process "mpv"` by
    // statusScript (which brings mpv frontmost first).
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return "key code 49 -- spacebar"
        case .skipBackward:
            return "key code 123 -- left arrow"
        case .skipForward:
            return "key code 124 -- right arrow"
        case .previousTrack:
            return "key code 43 using {shift down} -- < (shift+comma) for previous"
        case .nextTrack:
            return "key code 47 using {shift down} -- > (shift+period) for next"
        default:
            return ""
        }
    }
}
