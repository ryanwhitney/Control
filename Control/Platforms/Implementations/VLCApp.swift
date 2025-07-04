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
            try
                -- Check if VLC is currently running
                if not running then
                    return "Not running |||  |||  stopped  |||false"
                end if
                
                -- Check playback status
                if playing then
                    -- Attempt to get the name of the current media item
                    try
                        set mediaName to name of current item
                    on error
                        set mediaName to "Unknown media"
                    end try
                    return  mediaName & "|||   ||| true ||| true"
                else
                    try
                        set mediaName to name of current item
                        return mediaName & "|||   ||| false ||| false "
                    on error
                        return "Nothing playing |||   ||| false ||| false"
                    end try
                end if
                
            on error errMsg
                -- Handle errors gracefully
                if errMsg contains "Not authorized to send Apple events" then
                    error errMsg
                else
                    return "Error: " & errMsg & "||| false |||false"
                end if
            end try
        end tell
        """
    }
    
    func fetchState() -> String { statusScript() }
    
    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(actionLines: executeAction(action))
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
