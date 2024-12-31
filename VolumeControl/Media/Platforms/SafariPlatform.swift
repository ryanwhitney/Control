import Foundation

struct SafariPlatform: MediaPlatform {
    let id = "safari"
    let name = "Safari (experimental)"
    
    let supportedActions: [MediaAction] = [
        .skipBackward(10),
        .playPauseToggle,
        .skipForward(10)
    ]
    
    private let statusScript = """
    tell application "Safari"
    if not (exists window 1) then
        return "No Safari windows open|||no-url|||No media found|||false"
    end if
    
    set currentTab to current tab of front window
    set tabTitle to name of currentTab
    set theURL to URL of currentTab
    
    set jsCheck to "
        (function() {
            const media = document.querySelector('video, audio');
            if (!media) return 'No media found|||false';
            const isPlaying = !media.paused && !media.ended && media.currentTime > 0;
            return (isPlaying ? 'Media playing' : 'Media paused') + '|||' + isPlaying;
        })();
    "
    
    try
        set mediaStatus to do JavaScript jsCheck in currentTab
        return tabTitle & "|||" & theURL & "|||" & mediaStatus
    on error
        return tabTitle & "|||" & theURL & "|||No media found|||false"
    end try
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
            error: "Failed to parse Safari state"
        )
    }
    
    func executeAction(_ action: MediaAction) -> String {
        switch action {
        case .playPauseToggle:
            return """
            tell application "Safari"
                if (count of windows) > 0 then
                    tell current tab of front window
                        do JavaScript "
                            (function() {
                                const media = document.querySelector('video, audio');
                                if (media) {
                                    if (media.paused) media.play();
                                    else media.pause();
                                }
                            })();
                        "
                    end tell
                end if
            end tell
            """
        case .skipForward(let seconds):
            return """
            tell application "Safari"
                if (count of windows) > 0 then
                    tell current tab of front window
                        do JavaScript "
                            (function() {
                                const media = document.querySelector('video, audio');
                                if (media) media.currentTime += \(seconds);
                            })();
                        "
                    end tell
                end if
            end tell
            """
        case .skipBackward(let seconds):
            return """
            tell application "Safari"
                if (count of windows) > 0 then
                    tell current tab of front window
                        do JavaScript "
                            (function() {
                                const media = document.querySelector('video, audio');
                                if (media) media.currentTime -= \(seconds);
                            })();
                        "
                    end tell
                end if
            end tell
            """
        default:
            return ""
        }
    }
} 
