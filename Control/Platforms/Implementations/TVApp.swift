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
    
    func isRunningScript() -> String {
        """
        tell application "System Events" to set isAppOpen to exists (processes where name is "TV")
        return isAppOpen as text
        """
    }
    
    private let statusScript = """
    tell application "TV"
    -- Grab the raw player state: can be "playing", "paused", or "stopped".
    set rawState to player state as text
    
    -- Try to get the current track, which might fail if truly no track is loaded.
    set currentTrack to missing value
    try
        set currentTrack to name of current track
    end try
    try
        set frontWindow to name of front window
    end try
    
    if currentTrack is not missing value then
        set trackName to currentTrack
        set showName to "No show"
        if rawState is "playing" then
            -- Standard playing scenario
            return trackName & "|||" & showName & "|||" & "playing" & "|||" & "true"
        else if rawState is "paused" or rawState is "stopped" then
            -- If there's a valid track but the state is "stopped" or "paused," treat it as paused
            return trackName & "|||" & showName & "|||" & "paused" & "|||" & "false"
        end if
    else if frontWindow is not "TV" then
        if rawState is "playing" then
            return frontWindow & "|||" & frontWindow & "|||" & "playing" & "|||" & "true"
        else
            return frontWindow & "|||" & frontWindow & "|||" & "paused" & "|||" & "false"
        end if
    else
        -- If we can't retrieve a track, there's truly no video playing.
        return "No video playing|||No show|||stopped|||false"
    end if
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
            title: "",
            subtitle: "",
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
            activate
            try
            set currentPosition to player position
            if currentPosition is not missing value then
            set player position to currentPosition - 10
            else
            -- Fallback for streaming content
            tell application "System Events"
                -- Target the TV app directly
                tell process "TV"
                    key code 123 -- Right Arrow
                end tell
            end tell
            end if
            on error errMsg
            return "Error: " & errMsg
            end try
            end tell

            """
        case .skipForward:
            return """
            tell application "TV"
            activate
            try
            set currentPosition to player position
            if currentPosition is not missing value then
            set player position to currentPosition + 10
            else
            -- Fallback for streaming content
            tell application "System Events"
                -- Target the TV app directly
                tell process "TV"
                    key code 124 -- Right Arrow
                end tell
            end tell
            end if
            on error errMsg
            return "Error: " & errMsg
            end try
            end tell
            """
        default:
            return ""
        }
    }
} 
