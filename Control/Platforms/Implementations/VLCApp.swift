import Foundation

struct VLCApp: AppPlatform {
    let id = "vlc"
    let name = "VLC"
    let defaultEnabled = false
    
    var supportedActions: [ActionConfig] {
        [.previousTrack, .skipBackward(10), .playPause, .skipForward(10), .nextTrack]
    }


    /// `fetchState()` self-guards (and is run bare by PermissionsView), so the
    /// generic combinedStatusScript wrapper — a second System Events process
    /// enumeration per poll — is skipped.
    var fetchStateIsSelfGuarding: Bool { true }

    /// The single VLC script for both status polls and actions.
    ///
    /// The "tell VLC" body lives in a string variable executed via `run script`
    /// to avoid opening VLC from a running/status check: the interactive
    /// osascript shell executes line by line, so a "tell VLC" block behind a
    /// >0 process count check can run even if the check fails. Putting the
    /// script in a variable that is only run if the check succeeds fixes this.
    ///
    /// Self-contained (brings its own System Events tell): status polls return
    /// the not-running sentinel without launching VLC, while an action on a
    /// closed VLC launches it — tapping play on the VLC tab opens the app.
    private func statusScript(precededBy actionScript: String = "") -> String {
        let sep = ScriptTokens.fieldSeparator
        let notRunningBranch = actionScript.isEmpty
            ? "return \"\(ScriptTokens.notRunning)\""
            : """
            activate application "VLC"
                    return "Nothing playing \(sep)   \(sep) paused \(sep) false"
            """
        return """
        tell application "System Events"
            set vlcScript to "tell application \\"VLC\\"
                \(actionScript)
                try
                    set mediaName to name of current item
                    if playing then
                        return mediaName & \\"\(sep)   \(sep) playing \(sep) true\\"
                    else
                        return mediaName & \\"\(sep)   \(sep) paused \(sep) false\\"
                    end if
                on error
                    if playing then
                        return \\"Unknown media \(sep)   \(sep) playing \(sep) true\\"
                    else
                        return \\"Nothing playing \(sep)   \(sep) paused \(sep) false\\"
                    end if
                end try
            end tell"
            if (count of (processes where name is "VLC")) > 0 then
                return run script vlcScript
            else
                \(notRunningBranch)
            end if
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func actionWithStatus(_ action: AppAction) -> String {
        let delayScript: String
        switch action {
        case .previousTrack, .nextTrack:
            // Track changes need more time to load new media
            delayScript = "delay 0.5"
        default:
            // Other actions need less time
            delayScript = ""
        }

        return statusScript(precededBy: executeAction(action) + "\n" + delayScript)
    }

    func parseState(_ output: String) -> AppState {
        // VLC's output carries an extra state-word field; the boolean is fourth.
        parseSeparatedState(output, isPlayingField: 3)
            ?? AppState(title: "", subtitle: "")
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return "play"
        case .skipBackward:
            return "step backward"
        case .skipForward:
            return "step forward"
        case .previousTrack:
            return "previous"
        case .nextTrack:
            return "next"
        default:
            return ""
        }
    }
} 
