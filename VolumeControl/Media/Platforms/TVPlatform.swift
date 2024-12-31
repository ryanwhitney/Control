import Foundation

struct TVPlatform: MediaPlatform {
    let id = "tv"
    let name = "TV"
    
    let supportedActions: [MediaAction] = [
        .skipBackward(10),
        .playPauseToggle,
        .skipForward(10)
    ]
    
    private let statusScript = """
    tell application "TV"
        if player state is stopped then
            return "No video playing|||No show|||stopped|||false"
        end if
        set videoName to name of current track
        set showName to show of current track
        set playerState to player state as text
        set isPlaying to player state is playing
        return videoName & "|||" & showName & "|||" & playerState & "|||" & isPlaying
    end tell
    """
    
    func fetchState() -> String {
        return statusScript
    }
    
    func parseState(_ output: String) -> MediaState {
        let components = output.components(separatedBy: "|||")
        if components.count >= 4 {
            return MediaState(
                title: components[0].trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: components[1].trimmingCharacters(in: .whitespacesAndNewlines),
                isPlaying: components[3].trimmingCharacters(in: .whitespacesAndNewlines) == "true",
                error: nil
            )
        }
        return MediaState(
            title: "Error",
            subtitle: nil,
            isPlaying: nil,
            error: "Failed to parse TV state"
        )
    }
    
    func executeAction(_ action: MediaAction) -> String {
        switch action {
        case .playPauseToggle:
            return """
            tell application "TV"
                playpause
            end tell
            """
        case .skipBackward:
            return """
            tell application "TV"
                set currentTime to player position
                set player position to (currentTime - 10)
            end tell
            """
        case .skipForward:
            return """
            tell application "TV"
                set currentTime to player position
                set player position to (currentTime + 10)
            end tell
            """
        default:
            return ""
        }
    }
} 