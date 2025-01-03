import Foundation

struct SafariApp: AppPlatform {
    let id = "safari"
    let name = "Safari"
    
    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in 
                isPlaying ? "pause.fill" : "play.fill"
            })
        ]
    }
    
    func isRunningScript() -> String {
        """
        tell application "System Events" to set isAppOpen to exists (processes where name is "Safari")
        return isAppOpen as text
        """
    }
    
    private let statusScript = """
    tell application "Safari"
        set windowCount to count of windows
        if windowCount is 0 then
            return "No windows open|||No media playing|||false"
        end if
        
        repeat with w in windows
            set tabCount to count of tabs of w
            repeat with t in tabs of w
                if t's URL starts with "https://www.youtube.com/watch" then
                    set videoTitle to t's name
                    set isPlaying to do JavaScript "document.querySelector('video').paused ? 'false' : 'true'" in t
                    return videoTitle & "|||YouTube|||" & isPlaying
                end if
            end repeat
        end repeat
        
        return "No media playing|||No media found|||false"
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
            error: "Failed to parse Safari state"
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return """
            tell application "Safari"
                set windowCount to count of windows
                if windowCount is 0 then return
                
                repeat with w in windows
                    set tabCount to count of tabs of w
                    repeat with t in tabs of w
                        if t's URL starts with "https://www.youtube.com/watch" then
                            do JavaScript "document.querySelector('video').click()" in t
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            return ""
        }
    }
} 
