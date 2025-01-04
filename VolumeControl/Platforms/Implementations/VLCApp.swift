import Foundation

struct VLCApp: AppPlatform {
    let id = "vlc"
    let name = "VLC"
    
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
        """
        tell application "System Events" to set isAppOpen to exists (processes where name is "VLC")
        return isAppOpen as text
        """
    }
    
    private let statusScript = """
    tell application "VLC"
        try
            -- Check if VLC is currently running
            if not running then
                return "VLC is not running|||stopped|||false"
            end if
            
            -- Check playback status
            if playing then
                -- Attempt to get the name of the current media item
                try
                    set mediaName to name of current item
                on error
                    set mediaName to "Unknown media"
                end try
                return mediaName & "|||playing|||true"
            else
                try
                    set mediaName to name of current item
                    return mediaName & "|||stopped|||false"
                on error
                    return "No media|||stopped|||false"
                end try
            end if
            
        on error errMsg
            -- Handle errors gracefully
            if errMsg contains "Not authorized to send Apple events" then
                error errMsg
            else
                return "Error: " & errMsg & "|||stopped|||false"
            end if
        end try
    end tell
    """
    
    func fetchState() -> String {
        return statusScript
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
            subtitle: "VLC is not running",
            isPlaying: nil,
            error: nil
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return """
            tell application "VLC"
                play
            end tell
            """
        case .skipBackward:
            return """
            tell application "VLC"
                step backward
            end tell
            """
        case .skipForward:
            return """
            tell application "VLC"
                step forward
            end tell
            """
        case .previousTrack:
            return """
            tell application "VLC"
                previous
            end tell
            """
        case .nextTrack:
            return """
            tell application "VLC"
                next
            end tell
            """
        }
    }
} 
