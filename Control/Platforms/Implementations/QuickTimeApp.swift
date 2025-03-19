import Foundation

struct QuickTimeApp: AppPlatform {
    let id = "quicktime"
    let name = "QuickTime Player"
    
    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .skipBackward(5), icon: "5.arrow.trianglehead.counterclockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(5), icon: "5.arrow.trianglehead.clockwise")
        ]
    }
    
    func isRunningScript() -> String {
        """
        tell application "System Events" to set isAppOpen to exists (processes where name is "QuickTime Player")
        return isAppOpen as text
        """
    }
    
    private let statusScript = """
    tell application "QuickTime Player"
        if not (exists document 1) then
            return "No document|||No media playing|||false"
        end if
        set docName to name of document 1
        if playing of document 1 then
            set playState to "playing"
        else
            set playState to "paused"
        end if
        return docName & "|||" & playState & "|||" & (playing of document 1 as text)
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
            subtitle: "",
            isPlaying: nil,
            error: "Failed to parse QuickTime state"
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .skipBackward:
            return """
            tell application "QuickTime Player"
                if not (exists document 1) then return
                set theDocument to document 1
                set currentTime to current time of theDocument
                set newTime to currentTime - 5
                if newTime < 0 then set newTime to 0
                set current time of theDocument to newTime
            end tell
            """
        case .skipForward:
            return """
            tell application "QuickTime Player"
                if not (exists document 1) then return
                set theDocument to document 1
                set currentTime to current time of theDocument
                set videoDuration to duration of theDocument
                set newTime to currentTime + 5
                if newTime > videoDuration then set newTime to videoDuration - 0.01
                set current time of theDocument to newTime
            end tell
            """
        case .playPauseToggle:
            return """
            tell application "QuickTime Player"
                if exists document 1 then
                    tell document 1
                        if playing then
                            pause
                        else
                            play
                        end if
                    end tell
                end if
            end tell
            """
        default:
            return ""
        }
    }
} 
