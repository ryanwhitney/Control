import Foundation

struct VLCApp: AppPlatform {
    let id = "vlc"
    let name = "VLC"
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
        "tell application \"System Events\" to exists (processes where name is \"VLC\")"
    }
    
    private func defensiveStatusScript(actionLines: String = "") -> String {
        // This is to avoid opening VLC from a running/status check.
        // The interactive osascript shell executes line by line,
        // so if a "tell VLC" block is behind a >0 process count check,
        // it can run even if the check fails. Putting the script in a
        // variable that is only defined if the check succeeds fixes this.
        """
        -- this relies on being wrapped in the outer Tell System Events block
        set vlcScript to "tell application \\"VLC\\"
            \(actionLines)
            try
                set mediaName to name of current item
                if playing then
                    return mediaName & \\"|||   ||| playing ||| true\\"
                else
                    return mediaName & \\"|||   ||| paused ||| false\\"
                end if
            on error
                if playing then
                    return \\"Unknown media |||   ||| playing ||| true\\"
                else
                    return \\"Nothing playing |||   ||| paused ||| false\\"
                end if
            end try
        end tell"
        if (count of (processes where name is "VLC")) > 0 then
            return run script vlcScript
        else if "\(actionLines)" is "" then
               return "NOT_RUNNING"
        end if
        """
    }
    
    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "System Events"
            if (count of (processes where name is "VLC")) = 0 then
                activate application "VLC"
                return "Nothing playing |||   ||| paused ||| false"
            else
                tell application "VLC"
                    \(actionLines)
                    try
                        set mediaName to name of current item
                        if playing then
                            return mediaName & "|||   ||| playing ||| true"
                        else
                            return mediaName & "|||   ||| paused ||| false"
                        end if
                    on error
                        if playing then
                            return "Unknown media |||   ||| playing ||| true"
                        else
                            return "Nothing playing |||   ||| paused ||| false"
                        end if
                    end try
                end tell
            end if
        end tell
        """
    }
    
    func fetchState() -> String { defensiveStatusScript() }
    
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
        
        return statusScript(actionLines: executeAction(action) + "\n" + delayScript)
    }
    
    func parseState(_ output: String) -> AppState {
        let components = output.components(separatedBy: "|||")
        if components.count >= 4 {
            return AppState(
                title: components[0].trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: components[1].trimmingCharacters(in: .whitespacesAndNewlines),
                isPlaying: components[3].trimmingCharacters(in: .whitespacesAndNewlines) == "true",
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
