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
    
    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "VLC"
            \(actionLines)
            if not running then
                return "Not running |||  |||  stopped  |||false"
            end if
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
            delayScript = "delay 0.2"
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
        }
    }
} 
