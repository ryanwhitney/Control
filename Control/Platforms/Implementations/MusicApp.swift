import Foundation

struct MusicApp: AppPlatform {
    let id = "music"
    let name = "Music"
    let defaultEnabled = true

    var supportedActions: [ActionConfig] {
        [
            ActionConfig(action: .previousTrack, icon: "backward.end.fill"),
            ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in 
                isPlaying ? "pause.fill" : "play.fill"
            }),
            ActionConfig(action: .nextTrack, icon: "forward.end.fill")
        ]
    }
    
    func isRunningScript() -> String {
        "tell application \"System Events\" to exists (processes where name is \"Music\")"
    }
    
    // Template status script that can optionally run action AppleScript first.
    private func statusScript(precededBy actionScript: String = "") -> String {
        """
        tell application "Music"
            \(actionScript)
            if player state is stopped then
                return "Nothing playing ~|VCF|~    ~|VCF|~ false"
            end if
            set trackName to name of current track
            set artistName to artist of current track
            set playerState to player state as text
            set isPlaying to player state is playing
            return trackName & "~|VCF|~" & artistName & "~|VCF|~" & isPlaying
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    // Override the default helper to make use of the shared template so the
    // action and status execute inside the same `tell application` block.
    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(precededBy: actionScript(for: action))
    }

    /// AppleScript run *before* the status read. Music's `next track` /
    /// `previous track` return before `current track` updates, so reading the
    /// status immediately races and reports the *previous* track — the UI then
    /// shows a stale title until the next refresh. For those actions, capture the
    /// current track id, issue the change, then poll (bounded, ~1s max) until the
    /// id actually changes — or playback stops — before falling through to the
    /// status read. It exits the instant Music advances (usually well under
    /// 200 ms), so it stays snappy; the stopped check keeps end-of-playlist from
    /// lingering on the old title for the full timeout. The only case that waits
    /// out the full ~1s is a single-track/repeat-one context where the track can
    /// never change — and there the title is identical anyway, so it's invisible.
    /// Other actions (e.g. play/pause) don't change the track and read immediately.
    private func actionScript(for action: AppAction) -> String {
        switch action {
        case .nextTrack, .previousTrack:
            return """
            set previousTrackId to missing value
            try
                set previousTrackId to id of current track
            end try
            \(executeAction(action))
            repeat 20 times
                try
                    if player state is stopped then exit repeat
                    if id of current track is not previousTrackId then exit repeat
                end try
                delay 0.05
            end repeat
            """
        default:
            return executeAction(action)
        }
    }
    
    func parseState(_ output: String) -> AppState {
        let components = output.components(separatedBy: "~|VCF|~")
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
            error: "Error"
        )
    }
    
    func executeAction(_ action: AppAction) -> String {
        switch action {
        case .playPauseToggle:
            return "playpause"
        case .previousTrack:
            return "previous track"
        case .nextTrack:
            return "next track"
        default:
            return ""
        }
    }
} 
