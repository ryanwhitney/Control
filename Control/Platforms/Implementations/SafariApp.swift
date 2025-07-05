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

    func isRunningScript() -> String {
        // A simple, direct check. If this fails, the issue is fundamental.
        "tell application \"System Events\" to return (exists (processes where name is \"Safari\"))"
    }

    private func jsForStatus() -> String {
        return "(function() { const v = document.querySelector('video'); if (!v) return 'No video found|||Safari|||false'; const title = document.title.replace(' - YouTube', '') || 'Unknown Video'; const site = window.location.hostname.replace('www.', ''); const playing = !v.paused && !v.ended; return title + '|||' + site + '|||' + playing; })();"
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
        // Wrap in an IIFE for robust execution, which was missing before.
        return "(function() { \(innerJs) })();"
    }

    func fetchState() -> String {
        let js = jsForStatus()
        // Re-add window check for robustness.
        return """
        tell application "Safari"
            if (count of windows) is 0 then
                return "No windows open|||Safari|||false"
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
                return "No windows open|||Safari|||false"
            end if
            do JavaScript "\(actionJs)" in current tab of front window
            delay 0.3
            return do JavaScript "\(statusJs)" in current tab of front window
        end tell
        """
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
        
        // Handle cases where the script might return fewer components
        if !output.isEmpty && !output.contains("|||") {
            return AppState(title: output, subtitle: "Safari", isPlaying: nil)
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
