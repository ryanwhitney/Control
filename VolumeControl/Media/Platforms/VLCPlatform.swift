import Foundation

struct VLCPlatform: MediaPlatform {
    let id = "vlc"
    let name = "VLC"
    
    let supportedActions: [MediaAction] = [
        .skipBackward(10),
        .playPauseToggle,
        .skipForward(10)
    ]
    
    private let statusScript = """
    tell application "VLC"
        if not playing then
            return "No media|||stopped|||false"
        end if
        set currentItem to current item
        if currentItem is missing value then
            return "No media|||stopped|||false"
        end if
        set mediaName to name of currentItem
        if playing then
            return mediaName & "|||playing|||true"
        else
            return mediaName & "|||paused|||false"
        end if
    end tell
    """
    
    func fetchState() -> String {
        return statusScript
    }
    
    func parseState(_ output: String) -> MediaState {
        let components = output.components(separatedBy: "|||")
        if components.count >= 3 {
            return MediaState(
                title: components[0].trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: components[1].trimmingCharacters(in: .whitespacesAndNewlines),
                isPlaying: components[2].trimmingCharacters(in: .whitespacesAndNewlines) == "true",
                error: nil
            )
        }
        return MediaState(
            title: "Error",
            isPlaying: nil,
            error: "Failed to parse VLC state"
        )
    }
    
    func executeAction(_ action: MediaAction) -> String {
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