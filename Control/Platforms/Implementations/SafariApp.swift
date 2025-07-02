import Foundation

struct SafariApp: AppPlatform {
    let id = "safari"
    let name = "Safari"
    let defaultEnabled = false
    let experimental = true
    let reasonForExperimental = "Only looks for video in the current tab of the frontmost window. Does not work with content in iframes. Play/pause may be unreliable."

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
        tell application "System Events" to set isAppOpen to exists (processes where name is "Safari")
        return isAppOpen as text
        """
    }

    private let statusScript = """
    tell application "Safari"
        set windowCount to count of windows
        if windowCount is 0 then
            return "Nothing playing |||   ||| false ||| false"
        end if
        
        -- Check the current tab in the frontmost window only
        try
            set currentTab to current tab of window 1
            set hasVideo to do JavaScript "document.querySelector('video') !== null" in currentTab
            if hasVideo then
                set videoScript to "
                    var video = document.querySelector('video');
                    var title = document.title || 'Unknown Video';
                    var siteName = window.location.hostname.replace('www.', '');
                    var isPlaying = !video.paused && !video.ended;
                    title + ' ||| ' + siteName + ' ||| ' + (isPlaying ? 'true' : 'false') + ' ||| ' + (isPlaying ? 'true' : 'false');
                "
                set videoInfo to do JavaScript videoScript in currentTab
                return videoInfo
            end if
        end try
        
        return "Nothing playing |||   ||| false ||| false"
    end tell
    """

    func fetchState() -> String {
        return statusScript
    }

    func parseState(_ output: String) -> AppState {
        let components = output.components(separatedBy: "|||")
        
        if components.count >= 3 {
            let title = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlayingStr = components[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaying = isPlayingStr == "true"
            
            return AppState(
                title: title,
                subtitle: subtitle,
                isPlaying: isPlaying,
                error: nil
            )
        }
        return AppState(
            title: "",
            subtitle: "",
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
                
                -- Check the current tab in the frontmost window only
                try
                    set currentTab to current tab of window 1
                    set hasVideo to do JavaScript "document.querySelector('video') !== null" in currentTab
                    if hasVideo then
                        do JavaScript "
                            var video = document.querySelector('video');
                            if (video) {
                                if (video.paused || video.ended) {
                                    video.play();
                                } else {
                                    video.pause();
                                }
                            }
                        " in currentTab
                    end if
                end try
            end tell
            """
        case .skipForward(let seconds):
            return """
            tell application "Safari"
                set windowCount to count of windows
                if windowCount is 0 then return
                
                -- Check the current tab in the frontmost window only
                try
                    set currentTab to current tab of window 1
                    set hasVideo to do JavaScript "document.querySelector('video, audio') !== null" in currentTab
                    if hasVideo then
                        do JavaScript "
                            (function() {
                                const media = document.querySelector('video, audio');
                                if (media) media.currentTime += \(seconds);
                            })();
                        " in currentTab
                    end if
                end try
            end tell
            """
        case .skipBackward(let seconds):
            return """
            tell application "Safari"
                set windowCount to count of windows
                if windowCount is 0 then return
                
                -- Check the current tab in the frontmost window only
                try
                    set currentTab to current tab of window 1
                    set hasVideo to do JavaScript "document.querySelector('video, audio') !== null" in currentTab
                    if hasVideo then
                        do JavaScript "
                            (function() {
                                const media = document.querySelector('video, audio');
                                if (media) media.currentTime -= \(seconds);
                            })();
                        " in currentTab
                    end if
                end try
            end tell
            """
        default:
            return ""
        }
    }
}
