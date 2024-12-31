import Foundation

struct MusicPlatform: MediaPlatform {
    let id = "music"
    let name = "Music"
    
    let supportedActions: [MediaAction] = [
        .skipBackward(1),
        .playPauseToggle,
        .skipForward(1)
    ]
    
    private let statusScript = """
    tell application "Music"
        if player state is stopped then
            return "No track playing|||No artist|||stopped|||false"
        end if
        set trackName to name of current track
        set artistName to artist of current track
        set playerState to player state as text
        set isPlaying to player state is playing
        return trackName & "|||" & artistName & "|||" & playerState & "|||" & isPlaying
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
            error: "Failed to parse Music state"
        )
    }
    
    func executeAction(_ action: MediaAction) -> String {
        switch action {
        case .playPauseToggle:
            return """
            tell application "Music"
                playpause
            end tell
            """
        case .skipBackward:
            return """
            tell application "Music"
                previous track
            end tell
            """
        case .skipForward:
            return """
            tell application "Music"
                next track
            end tell
            """
        default:
            return ""
        }
    }
} 
