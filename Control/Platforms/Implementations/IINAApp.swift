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
    // IINA is always foregrounded — reading play/pause requires its menu bar —
    // but focus is only restored for status-only polls: after a user action,
    // IINA deliberately stays in front.
    private func statusScript(precededBy actionScript: String = "") -> String {
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "System Events"
            if (count of (processes where name is "IINA")) = 0 then
                return "Not running\(sep)   \(sep)false"
            end if
            set isPlaying to false
            set previousFrontmostApp to null
            set shouldRestoreOrder to false
            if not (frontmost of process "IINA") then
                \(captureAndForegroundProcessFragment("IINA"))
                if "\(actionScript)" is "" then
                    set shouldRestoreOrder to true
                end if
            end if
            tell process "IINA"
                -- Execute any action lines
                if "\(actionScript)" is not "" then
                    \(actionScript)
                end if
                -- Get the playing state
                set playPauseMenu to menu item 1 of menu "Playback" of menu bar 1
                set isPlaying to (name of playPauseMenu contains "Pause")
                -- Get window info
                if (count of windows) > 0 then
                    set windowTitle to name of front window
                    set resultString to windowTitle & "\(sep)   \(sep)" & isPlaying
                else
                    set resultString to "No window\(sep)   \(sep)" & isPlaying
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
 
