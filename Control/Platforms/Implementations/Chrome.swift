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

    // Checks if Chrome is running
    func isRunningScript() -> String {
        """
        tell application "System Events" to set isAppOpen to exists (processes where name is "Google Chrome")
        return isAppOpen as text
        """
    }

    // Template status script that can optionally inject action AppleScript
    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "Google Chrome"
            \(actionLines)
            set windowCount to number of windows
            if windowCount is 0 then
                return "No windows open|||No media playing|||false"
            end if
            
            repeat with w in windows
                set tabCount to number of tabs in w
                repeat with t in tabs of w
                    set theURL to URL of t
                    if theURL starts with \"https://www.youtube.com/watch\" then
                        set videoTitle to title of t
                        set isPlaying to execute t javascript \"document.querySelector('video').paused ? 'false' : 'true'\"
                        return videoTitle & \"|||YouTube|||\" & isPlaying
                    end if
                end repeat
            end repeat
            
            return \"No media playing|||No media found|||false\"
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(actionLines: executeAction(action))
    }

    // Parses the output into a friendly AppState
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
            error: "Failed to parse Chrome state"
        )
    }

    // Executes the given AppAction in Chrome via AppleScript
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return """
            set windowCount to number of windows
            if windowCount is 0 then return

            repeat with w in windows
                set tabCount to number of tabs in w
                repeat with t in tabs of w
                    set theURL to URL of t
                    if theURL starts with \"https://www.youtube.com/watch\" then
                        execute t javascript \"document.querySelector('video').click()\"
                        return
                    end if
                end repeat
            end repeat
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
