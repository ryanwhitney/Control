import Foundation

struct VLCApp: AppPlatform {
    let id = "vlc"
    let name = "VLC"
    
    let supportedActions: [AppAction] = [
        .skipBackward(10),
        .playPauseToggle,
        .skipForward(10)
    ]
    
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
        case .skipForward(let seconds):
            return """
            tell application "VLC"
                set currentTime to current time
                set current time to (currentTime + \(seconds))
            end tell
            """
        case .skipBackward(let seconds):
            return """
            tell application "VLC"
                set currentTime to current time
                set current time to (currentTime - \(seconds))
            end tell
            """
        default:
            return ""
        }
    }
} 
