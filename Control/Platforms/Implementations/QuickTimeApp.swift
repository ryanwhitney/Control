import Foundation

struct QuickTimeApp: AppPlatform {
    let id = "quicktime"
    let name = "QuickTime Player"
    let defaultEnabled = true

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
        tell application "System Events"
            if exists (processes where name is "QuickTime Player") then
                return "true"
            else
                return "false"
            end if
        end tell
        """
    }
    
    private func statusScript(precededBy actionScript: String = "") -> String {
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "QuickTime Player"
            \(actionScript)
            if not (exists document 1) then
                return "Nothing playing \(sep)   \(sep)false"
            end if
            set docName to name of document 1
            if playing of document 1 then
                set playState to "playing"
            else
                set playState to "paused"
            end if
            return docName & "\(sep)   \(sep)" & (playing of document 1 as text)
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func parseState(_ output: String) -> AppState {
        parseSeparatedState(output)
            ?? AppState(title: "", subtitle: "", isPlaying: nil, error: "Failed to parse QuickTime state")
    }

    // No bare `return` in these scripts: they're injected at the top of
    // statusScript's tell block, and a `return` would exit the whole combined
    // script before the status section runs (leaving the UI stale).
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .skipBackward:
            return """
            if exists document 1 then
                set theDocument to document 1
                set currentTime to current time of theDocument
                set newTime to currentTime - 5
                if newTime < 0 then set newTime to 0
                set current time of theDocument to newTime
            end if
            """
        case .skipForward:
            return """
            if exists document 1 then
                set theDocument to document 1
                set currentTime to current time of theDocument
                set videoDuration to duration of theDocument
                set newTime to currentTime + 5
                if newTime > videoDuration then set newTime to videoDuration - 0.01
                set current time of theDocument to newTime
            end if
            """
        case .playPauseToggle:
            return """
            if exists document 1 then
                tell document 1
                    if playing then
                        pause
                    else
                        play
                    end if
                end tell
            end if
            """
        default:
            return ""
        }
    }
    
    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(precededBy: executeAction(action))
    }
} 
