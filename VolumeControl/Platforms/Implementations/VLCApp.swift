import Foundation

struct VLCApp: AppPlatform {
    let id = "vlc"
    let name = "VLC"
    
    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .previousTrack, icon: "backward.end.fill"),
            ActionConfig(action: .skipBackward(10), icon: "10.arrow.trianglehead.clockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(10), icon: "10.arrow.trianglehead.clockwise"),
            ActionConfig(action: .nextTrack, icon: "forward.end.fill")
        ]
    }
    
    private let statusScript = """
    tell application "VLC"
        try
            set mediaName to name of current item
            if playing then
                return mediaName & "|||playing|||true"
            else
                return mediaName & "|||paused|||false"
            end if
        on error
            return "No media|||stopped|||false"
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
            title: "Error",
            subtitle: nil,
            isPlaying: nil,
            error: "Failed to parse VLC state"
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
