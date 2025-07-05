import Foundation

struct TVApp: AppPlatform {
    let id = "tv"
    let name = "TV"
    let defaultEnabled = true

    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .skipBackward(10), icon: "10.arrow.trianglehead.counterclockwise"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .skipForward(10), icon: "10.arrow.trianglehead.clockwise")
        ]
    }
    
    func isRunningScript() -> String {
        "tell application \"System Events\" to exists (processes where name is \"TV\")"
    }
    
    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "TV"
            \(actionLines)
            try
                -- Grab the raw player state: can be "playing", "paused", or "stopped".
                set rawState to player state as text
                
                -- Initialize variables
                set currentTrack to missing value
                set frontWindow to missing value
                set trackName to ""
                set showName to ""
                
                -- Try to get the current track
                try
                    set currentTrack to name of current track
                    set trackName to currentTrack
                    
                    -- Try to get show name if it's a TV show
                    try
                        set currentProperties to properties of current track
                        if media kind of currentProperties is TV show then
                            set showName to show of current track
                        end if
                    end try
                end try
                
                -- If no track, try to get window name
                if currentTrack is missing value then
                    try
                        set frontWindow to name of front window
                        if frontWindow is not "TV" then
                            set trackName to frontWindow
                        end if
                    end try
                end if
                
                -- Determine final output based on what we found
                if trackName is "" then
                    return "Nothing playing |||   ||| stopped ||| false"
                else if rawState is "playing" then
                    return trackName & "|||" & showName & "|||playing|||true"
                else
                    return trackName & "|||" & showName & "|||paused|||false"
                end if
                
            on error errMsg
                return "Error: " & errMsg & "||| ||| error ||| false"
            end try
        end tell
        """
    }
    
    func fetchState() -> String { statusScript() }
    
    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(actionLines: executeAction(action))
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
            title: "",
            subtitle: "",
            isPlaying: nil,
            error: "Failed to parse TV state"
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return "playpause"
        case .skipBackward:
            return """
            activate
            try
                set currentPosition to player position
                if currentPosition is not missing value then
                    set player position to currentPosition - 10
                else
                    -- Fallback for streaming content
                    tell application "System Events"
                        tell process "TV" to key code 123 -- Left Arrow
                    end tell
                end if
            on error errMsg
                return "Error: " & errMsg
            end try
            """
        case .skipForward:
            return """
            activate
            try
                set currentPosition to player position
                if currentPosition is not missing value then
                    set player position to currentPosition + 10
                else
                    tell application "System Events" to tell process "TV" to key code 124 -- Right Arrow
                end if
            on error errMsg
                return "Error: " & errMsg
            end try
            """
        default:
            return ""
        }
    }
} 
