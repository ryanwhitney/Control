import Foundation

struct IINAApp: AppPlatform {
    let id = "iina"
    let name = "IINA"
    let defaultEnabled = false
    
    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .previousTrack, icon: "backward.end.fill"),
            ActionConfig(action: .skipBackward(10), icon: "10.arrow.trianglehead.counterclockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(10), icon: "10.arrow.trianglehead.clockwise"),
            ActionConfig(action: .nextTrack, icon: "forward.end.fill")
        ]
    }
    
    func isRunningScript() -> String {
        // Match Spotify's pattern for System Events
        """
        tell application "System Events"
            if exists (processes where name is "IINA") then
                return "true"
            else
                return "false"
            end if
        end tell
        """
    }
    
    // Everything must be done through System Events since IINA has no AppleScript support
    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "System Events"
            \(actionLines)
            if not (exists (processes where name is "IINA")) then
                return "Not running|||   |||false"
            end if
        set isPlaying to false
            try
                tell application "IINA" to activate
                tell process "IINA"
                    set playPauseMenu to menu item 1 of menu "Playback" of menu bar 1
                    set isPlaying to (name of playPauseMenu contains "Pause")
                end tell
            end try
            tell process "IINA"
                if (count of windows) > 0 then
                    set windowTitle to name of front window
                    return windowTitle & "|||   |||" & isPlaying
                else
                    return "No window|||   |||" & isPlaying
                end if
            end tell
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func actionWithStatus(_ action: AppAction) -> String {
        // Add delay after action like Spotify does
        let delayScript = "delay 0.3\n"
        return statusScript(actionLines: executeAction(action) + "\n" + delayScript)
    }
    
    func parseState(_ output: String) -> AppState {
        let components = output.components(separatedBy: "|||")
        if components.count >= 3 {
            var title = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
            // IINA often includes the full path after a dash, so we strip it.
            if let range = title.range(of: "  —  ") {
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            return AppState(
                title: title,
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
        // Actions need IINA to be frontmost
        var cmd = "tell process \"IINA\" to set frontmost to true\n"
        cmd += "delay 0.1\n"
        
        switch action {
        case .playPauseToggle:
            cmd += "keystroke space"
        case .skipBackward:
            cmd += "key code 123"
        case .skipForward:
            cmd += "key code 124"
        case .previousTrack:
            cmd += "key code 123 using {command down}"
        case .nextTrack:
            cmd += "key code 124 using {command down}"
        }
        
        return cmd
    }
}
 
