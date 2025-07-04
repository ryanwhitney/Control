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
        "tell application \"System Events\" to exists (processes where name is \"Safari\")"
    }

    private func statusScript(actionLines: String = "") -> String {
        """
        tell application "Safari"
            \(actionLines)
            set windowCount to count of windows
            if windowCount is 0 then
                return "Nothing playing |||   ||| false ||| false"
            end if
            try
                set currentTab to current tab of window 1
                set videoScript to "
                        (function() {
                            var video = document.querySelector('video');
                            if (!video) return 'Nothing playing |||   ||| false ||| false';
                            var title = document.title.replace(' - YouTube', '') || 'Unknown Video';
                            var siteName = window.location.hostname.replace('www.', '');
                            var isPlaying = !video.paused && !video.ended;
        
                            return title + ' ||| ' + siteName + ' ||| ' + (isPlaying ? 'true' : 'false') + ' ||| ' + (isPlaying ? 'true' : 'false');
                        })();
                    "
                set videoInfo to do JavaScript videoScript in currentTab
                return videoInfo
            end try
            
            return "Nothing playing |||   ||| false ||| false"
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(actionLines: executeAction(action))
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
            set windowCount to count of windows
            if windowCount is 0 then return
            try
                set currentTab to current tab of window 1
                do JavaScript "
                    (function() {
                        var video = document.querySelector('video');
                        if (video) {
                            if (video.paused || video.ended) {
                                video.play();
                            } else {
                                video.pause();
                            }
                        }
                    })();
                " in currentTab
            end try
            """
        case .skipForward(let seconds):
            return """
            set windowCount to count of windows
            if windowCount is 0 then return
            try
                set currentTab to current tab of window 1
                do JavaScript "
                    (function() {
                        const media = document.querySelector('video, audio');
                        if (media) media.currentTime += \(seconds);
                    })();
                " in currentTab
            end try
            """
        case .skipBackward(let seconds):
            return """
            set windowCount to count of windows
            if windowCount is 0 then return
            
            try
                set currentTab to current tab of window 1
                do JavaScript "
                    (function() {
                        const media = document.querySelector('video, audio');
                        if (media) media.currentTime -= \(seconds);
                    })();
                " in currentTab
            end try
            """
        default:
            return ""
        }
    }
}
