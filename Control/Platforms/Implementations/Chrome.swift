import Foundation

struct ChromeApp: AppPlatform {
    let id = "chrome"
    let name = "Google Chrome"
    let defaultEnabled = false
    let experimental = true
    let reasonForExperimental = "Only works with YouTube videos in Chrome. Requires Chrome to be running and may be unreliable."

    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .skipBackward(5), icon: "5.arrow.trianglehead.counterclockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(5), icon: "5.arrow.trianglehead.clockwise")
        ]
    }

    // Template status script that can optionally inject action AppleScript
    private func statusScript(precededBy actionScript: String = "") -> String {
        """
        tell application "Google Chrome"
            \(actionScript)
            set windowCount to number of windows
            if windowCount is 0 then
                return "No windows open\(ScriptTokens.fieldSeparator)No media playing\(ScriptTokens.fieldSeparator)false"
            end if

            repeat with w in windows
                set tabCount to number of tabs in w
                repeat with t in tabs of w
                    set theURL to URL of t
                    if theURL starts with \"https://www.youtube.com/watch\" then
                        set videoTitle to title of t
                        set isPlaying to execute t javascript \"document.querySelector('video').paused ? 'false' : 'true'\"
                        return videoTitle & \"\(ScriptTokens.fieldSeparator)YouTube\(ScriptTokens.fieldSeparator)\" & isPlaying
                    end if
                end repeat
            end repeat

            return \"No media playing\(ScriptTokens.fieldSeparator)No media found\(ScriptTokens.fieldSeparator)false\"
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(precededBy: executeAction(action))
    }

    // Parses the output into a friendly AppState
    func parseState(_ output: String) -> AppState {
        parseSeparatedState(output)
            ?? AppState(title: "", subtitle: "", isPlaying: nil, error: "Failed to parse Chrome state")
    }

    // Executes the given AppAction in Chrome via AppleScript
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            // No bare `return` here: this script is injected at the top of
            // statusScript's tell block, and a `return` would exit the whole
            // combined script before the status section runs (leaving the UI
            // stale after every tap).
            return """
            set didToggle to false
            if (number of windows) > 0 then
                repeat with w in windows
                    if didToggle then exit repeat
                    repeat with t in tabs of w
                        set theURL to URL of t
                        if theURL starts with \"https://www.youtube.com/watch\" then
                            execute t javascript \"document.querySelector('video').click()\"
                            set didToggle to true
                            exit repeat
                        end if
                    end repeat
                end repeat
            end if
            """

        case .skipForward(let seconds):
            return """
            if (count of windows) > 0 then
                tell active tab of front window
                    execute javascript "
                    (function() {
                        const media = document.querySelector('video, audio');
                        if (media) media.currentTime += \(seconds);
                    })();
                    "
                end tell
            end if
            """

        case .skipBackward(let seconds):
            return """
            if (count of windows) > 0 then
                tell active tab of front window
                    execute javascript "
                    (function() {
                        const media = document.querySelector('video, audio');
                        if (media) media.currentTime -= \(seconds);
                    })();
                    "
                end tell
            end if
            """

        default:
            return ""
        }
    }
}
