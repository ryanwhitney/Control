import Foundation

struct IINAApp: AppPlatform {
    let id = "iina"
    let name = "IINA"
    let defaultEnabled = false
    // Reading play/pause requires foregrounding IINA to reach its menu bar, so
    // it's kept out of the global sweep and refreshed only when its tab is visible.
    let checksStatusOnlyWhenVisible = true
    
    var supportedActions: [ActionConfig] {
        [.previousTrack, .skipBackward(10), .playPause, .skipForward(10), .nextTrack]
    }


    /// `fetchState()` self-guards (first lines below) and must stay valid
    /// stand-alone for PermissionsView, so combinedStatusScript's second
    /// System Events process check is skipped.
    var fetchStateIsSelfGuarding: Bool { true }

    // Everything must be done through System Events since IINA has no AppleScript support.
    // Reading play/pause requires IINA's menu bar, which System Events can only
    // reach while IINA is frontmost — but the window title is readable without
    // focus. So peek at the title first: with nothing loaded (no window, or an
    // untitled welcome/main window), report "Nothing playing" without ever
    // foregrounding. IINA only comes forward when a file is loaded (to read
    // play/pause) or an action needs delivering; focus is restored for
    // status-only polls, while after a user action IINA deliberately stays
    // in front.
    private func statusScript(precededBy actionScript: String = "") -> String {
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "System Events"
            if (count of (processes where name is "IINA")) = 0 then
                return "Not running\(sep)   \(sep)false"
            end if
            -- Titles of IINA's non-video windows: utility panels, plus the
            -- settings window (titled after whichever pane is selected). A
            -- video coincidentally named one of these reads as idle — rare
            -- and harmless next to settings panes reading as "playing".
            set ignoredTitles to {"Log Viewer", "Playback History", "Video Filters", "Audio Filters", "Downloads — Online Media", "User Scripts — User Scripts", "General", "UI", "Video/Audio", "Subtitle", "Network", "Control", "Key Bindings", "Advanced", "Plugins", "Utilities"}
            set isPlaying to false
            set previousFrontmostApp to null
            set shouldRestoreOrder to false
            set windowTitle to ""
            set videoWindow to missing value
            tell process "IINA"
                -- Front-to-back, first titled window that isn't a utility
                -- panel — so a Log Viewer in front doesn't hide the video.
                repeat with w in windows
                    set t to name of w
                    if t is not missing value and t is not "" and ignoredTitles does not contain t then
                        set windowTitle to t
                        set videoWindow to w
                        exit repeat
                    end if
                end repeat
            end tell
            -- No video window: report idle without foregrounding. This also
            -- covers actions — with nothing loaded a keystroke would land in
            -- whatever IINA window is focused (e.g. a settings search field).
            if windowTitle is "" then
                return "Nothing playing\(sep)   \(sep)false"
            end if
            if not (frontmost of process "IINA") then
                \(captureAndForegroundProcessFragment("IINA"))
                if "\(actionScript)" is "" then
                    set shouldRestoreOrder to true
                end if
            end if
            tell process "IINA"
                -- Execute any action lines. Keystrokes land on IINA's focused
                -- window, so raise the video window first — a settings/utility
                -- panel on top would otherwise swallow them.
                if "\(actionScript)" is not "" then
                    perform action "AXRaise" of videoWindow
                    delay 0.1
                    \(actionScript)
                end if
                -- Get the playing state
                set playPauseMenu to menu item 1 of menu "Playback" of menu bar 1
                set isPlaying to (name of playPauseMenu contains "Pause")
                -- Re-read the title: an action may have just loaded or changed it.
                set windowTitle to ""
                repeat with w in windows
                    set t to name of w
                    if t is not missing value and t is not "" and ignoredTitles does not contain t then
                        set windowTitle to t
                        exit repeat
                    end if
                end repeat
                if windowTitle is "" then
                    set resultString to "Nothing playing\(sep)   \(sep)" & isPlaying
                else
                    set resultString to windowTitle & "\(sep)   \(sep)" & isPlaying
                end if
            end tell
            \(restorePreviousFrontmostFragment())
            return resultString
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func actionWithStatus(_ action: AppAction) -> String {
        // statusScript foregrounds IINA and settles before reading, so no extra
        // delay is needed around the action.
        return statusScript(precededBy: executeAction(action))
    }
    
    func parseState(_ output: String) -> AppState {
        guard var state = parseSeparatedState(output) else {
            return AppState(title: "", subtitle: "")
        }
        // IINA shows "filename  —  /full/path" (two spaces + em dash).
        if let range = state.title.range(of: "  —  ") {
            state.title = String(state.title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return state
    }
    
    func executeAction(_ action: AppAction) -> String {
        // Only bring IINA to front (with small delay) if it's not already frontmost.
        let keyLine: String
        switch action {
        case .playPauseToggle:
            keyLine = "keystroke space"
        case .skipBackward:
            keyLine = "key code 123"
        case .skipForward:
            keyLine = "key code 124"
        case .previousTrack:
            keyLine = "key code 123 using {command down}"
        case .nextTrack:
            keyLine = "key code 124 using {command down}"
        default:
            keyLine = ""
        }

        return keyLine
    }
}
 
