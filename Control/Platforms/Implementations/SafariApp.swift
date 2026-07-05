import Foundation

struct SafariApp: AppPlatform {
    let id = "safari"
    let name = "Safari"
    let defaultEnabled = false
    let experimental = true
    let reasonForExperimental = "Only looks for video in the current tab of the frontmost window. Does not work with content in iframes. Play/pause may be unreliable."

    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .skipBackward(5), icon: "5.arrow.trianglehead.counterclockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(5), icon: "5.arrow.trianglehead.clockwise")
        ]
    }

    private func jsForStatus() -> String {
        let sep = ScriptTokens.fieldSeparator
        return "(function() { const v = document.querySelector('video'); if (!v) return 'No video found\(sep) \(sep)false'; const title = document.title.replace(' - YouTube', '') || 'Unknown Video'; const site = window.location.hostname.replace('www.', ''); const playing = !v.paused && !v.ended; return title + '\(sep)' + site + '\(sep)' + playing; })();"
    }

    private func jsForAction(_ action: AppAction) -> String {
        let innerJs: String
        switch action {
        case .playPauseToggle:
            innerJs = "const v = document.querySelector('video'); if (v) { v.paused ? v.play() : v.pause(); }"
        case .skipForward(let seconds):
            innerJs = "const v = document.querySelector('video'); if (v) v.currentTime += \(seconds);"
        case .skipBackward(let seconds):
            innerJs = "const v = document.querySelector('video'); if (v) v.currentTime -= \(seconds);"
        default:
            return ""
        }
        // Wrap in an IIFE so the injected statement runs in its own scope.
        return "(function() { \(innerJs) })();"
    }

    func fetchState() -> String {
        let js = jsForStatus()
        return """
        tell application "Safari"
            if (count of windows) is 0 then
                return "No windows open\(ScriptTokens.fieldSeparator) \(ScriptTokens.fieldSeparator)false"
            end if
            return do JavaScript "\(js)" in current tab of front window
        end tell
        """
    }

    func actionWithStatus(_ action: AppAction) -> String {
        let actionJs = jsForAction(action)
        let statusJs = jsForStatus()

        // Build a single, direct script with the window check.
        return """
        tell application "Safari"
            if (count of windows) is 0 then
                return "No windows open\(ScriptTokens.fieldSeparator) \(ScriptTokens.fieldSeparator)false"
            end if
            do JavaScript "\(actionJs)" in current tab of front window
            delay 0.15
            return do JavaScript "\(statusJs)" in current tab of front window
        end tell
        """
    }

    func parseState(_ output: String) -> AppState {
        if let state = parseSeparatedState(output) {
            return state
        }

        // Handle cases where the script might return fewer components
        if !output.isEmpty && !output.contains(ScriptTokens.fieldSeparator) {
            return AppState(title: output, subtitle: "", isPlaying: nil)
        }

        return AppState(
            title: "Error",
            subtitle: "Could not parse Safari state",
            isPlaying: nil,
            error: output
        )
    }

    // This function is not used when actionWithStatus is implemented, but is required by the protocol.
    func executeAction(_ action: AppAction) -> String {
        return ""
    }
}
