import Foundation

struct TVApp: AppPlatform {
    let id = "tv"
    let name = "TV"
    
    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .skipBackward(10), icon: "10.arrow.trianglehead.counterclockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(10), icon: "10.arrow.trianglehead.clockwise")
        ]
    }
    
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
            title: "Error",
            subtitle: nil,
            isPlaying: nil,
            error: "Failed to parse TV state"
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
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
