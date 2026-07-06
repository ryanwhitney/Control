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
            .previousTrack,
            .skipBackward(5),
            // Static play/pause glyph: mpv doesn't expose reliable play/pause
            // state over AppleScript, so a dynamic icon would misrepresent it.
            ActionConfig(action: .playPauseToggle, icon: "playpause.fill"),
            .skipForward(5),
            .nextTrack
        ]
    }

    /// `fetchState()` self-guards (first lines below) and must stay valid
    /// stand-alone for PermissionsView, so combinedStatusScript's second
    /// System Events process check is skipped.
    var fetchStateIsSelfGuarding: Bool { true }

    // mpv has no AppleScript dictionary, so everything goes through System Events.
    // Status reads the window title (no focus needed), so we only bring mpv
    // frontmost when there's an action to deliver — keystrokes go to the frontmost
    // app regardless of the enclosing `tell process`. Poll-only status never
    // steals focus, and focus is restored after an action.
    private func statusScript(precededBy actionScript: String = "") -> String {
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "System Events"
            if (count of (processes where name is "mpv")) = 0 then
                return "Not running\(sep)   \(sep)false"
            end if
            set previousFrontmostApp to null
            set shouldRestoreOrder to false
            if "\(actionScript)" is not "" then
                if not (frontmost of process "mpv") then
                    \(captureAndForegroundProcessFragment("mpv"))
                    set shouldRestoreOrder to true
                end if
            end if
            set resultString to "Nothing playing\(sep)   \(sep)false"
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
                    set resultString to cleanTitle & "\(sep)   \(sep)" & isPlaying
                end if
            end tell
            \(restorePreviousFrontmostFragment())
            return resultString
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(precededBy: executeAction(action))
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
