import Foundation
import SwiftUI

enum AppAction: Identifiable, Equatable {
    case skipForward(Int)
    case skipBackward(Int)
    case previousTrack
    case nextTrack
    case playPauseToggle
    case closeApp(String)

    var id: String {
        switch self {
        case .skipForward(let seconds): return "forward\(seconds)"
        case .skipBackward(let seconds): return "backward\(seconds)"
        case .previousTrack: return "previousTrack"
        case .nextTrack: return "nextTrack"
        case .playPauseToggle: return "playPauseToggle"
        case .closeApp: return "closeApp"
        }
    }
    
    var label: String {
        switch self {
        case .skipForward(let seconds):
            return "Forward \(seconds) seconds"
        case .skipBackward(let seconds):
            return "Back \(seconds) seconds"
        case .previousTrack:
            return "Previous track"
        case .nextTrack:
            return "Next track"
        case .playPauseToggle:
            return "Play/Pause"
        case .closeApp(let appName):
            return "Close \(appName)"
        }
    }

    /// Alternative spoken names for Voice Control ("Tap skip forward"), shorter
    /// and more natural than the descriptive VoiceOver labels.
    var inputLabels: [String] {
        switch self {
        case .skipForward(let seconds):
            return ["Skip forward", "Forward", "Forward \(seconds) seconds"]
        case .skipBackward(let seconds):
            return ["Skip back", "Back", "Back \(seconds) seconds"]
        case .previousTrack:
            return ["Previous track", "Previous"]
        case .nextTrack:
            return ["Next track", "Next"]
        case .playPauseToggle:
            return ["Play", "Pause", "Play pause"]
        case .closeApp(let appName):
            return ["Close \(appName)", "Close"]
        }
    }
}

struct ActionConfig: Identifiable {
    let action: AppAction
    let label: String
    let staticIcon: String
    let dynamicIcon: ((Bool) -> String)?
    
    var id: String { action.id }
    
    init(action: AppAction, icon: String) {
        self.action = action
        self.label = action.label
        self.staticIcon = icon
        self.dynamicIcon = nil
    }
    
    init(action: AppAction, dynamicIcon: @escaping (Bool) -> String) {
        self.action = action
        self.label = action.label
        self.staticIcon = dynamicIcon(false) // Default to not playing
        self.dynamicIcon = dynamicIcon
    }
}

extension ActionConfig: Equatable {
    static func == (lhs: ActionConfig, rhs: ActionConfig) -> Bool {
        // We only compare the action and staticIcon since closures can't be compared
        lhs.action == rhs.action && lhs.staticIcon == rhs.staticIcon
    }
}

/// The standard transport configs shared by the platform implementations.
extension ActionConfig {
    static let playPause = ActionConfig(action: .playPauseToggle, dynamicIcon: { isPlaying in
        isPlaying ? "pause.fill" : "play.fill"
    })
    static let previousTrack = ActionConfig(action: .previousTrack, icon: "backward.end.fill")
    static let nextTrack = ActionConfig(action: .nextTrack, icon: "forward.end.fill")

    static func skipBackward(_ seconds: Int) -> ActionConfig {
        ActionConfig(action: .skipBackward(seconds), icon: "\(seconds).arrow.trianglehead.counterclockwise")
    }
    static func skipForward(_ seconds: Int) -> ActionConfig {
        ActionConfig(action: .skipForward(seconds), icon: "\(seconds).arrow.trianglehead.clockwise")
    }
}

struct AppState: Equatable {
    var title: String
    var subtitle: String
    var isPlaying: Bool?
    var error: String?
}

protocol AppPlatform: Identifiable {
    var id: String { get }
    var name: String { get }
    var defaultEnabled: Bool { get }
    var checksStatusOnlyWhenVisible: Bool { get }
    var minActionInterval: TimeInterval { get }
    var fetchStateIsSelfGuarding: Bool { get }
    var experimental: Bool { get }
    var reasonForExperimental: String { get }
    var supportedActions: [ActionConfig] { get }
    var menuActions: [ActionConfig] { get }
    
    func fetchState() -> String
    func executeAction(_ action: AppAction) -> String
    func executeMenuActionWithStatus(_ action: AppAction) -> String
    func parseState(_ output: String) -> AppState
    func actionWithStatus(_ action: AppAction) -> String
}

extension AppPlatform {
    var experimental: Bool { false }
    var reasonForExperimental: String { "" }

    /// Most platforms expose status over AppleScript and can be polled quietly in
    /// the background as part of the global multi-app refresh. Apps without it
    /// (IINA, mpv) must foreground the Mac app or UI-script it via System Events
    /// to read status, so they override this to `true`: the bulk sweep skips them
    /// and they're refreshed only when their own tab is the one on screen.
    var checksStatusOnlyWhenVisible: Bool { false }

    /// Minimum spacing between successive user actions for this platform;
    /// 0 disables rate limiting. Platforms whose actions can flood a channel
    /// (e.g. TV's key-code driven skips) override this.
    var minActionInterval: TimeInterval { 0 }

    /// True when `fetchState()` already guards the app-not-running case itself
    /// (IINA/mpv/VLC, whose scripts must stay valid stand-alone because
    /// PermissionsView runs them bare). `combinedStatusScript()` then skips its
    /// System Events wrapper, avoiding a second process-enumeration per poll.
    var fetchStateIsSelfGuarding: Bool { false }

    /// Default status parse: the shared separated shape below, or an empty
    /// error state when the output doesn't match. Platforms that post-process
    /// the parse (IINA, Safari) or read a different field (VLC) override this.
    func parseState(_ output: String) -> AppState {
        parseSeparatedState(output)
            ?? AppState(title: "", subtitle: "", error: "Unable to parse status")
    }

    /// Parses the shared "title ~|VCF|~ subtitle ~|VCF|~ … ~|VCF|~ isPlaying"
    /// status shape (see `ScriptTokens.fieldSeparator`). Returns nil when the
    /// output doesn't carry enough fields so platforms supply their own
    /// fallback. `isPlayingField` names the index carrying the boolean for
    /// scripts with extra fields (VLC).
    func parseSeparatedState(_ output: String, isPlayingField: Int = 2) -> AppState? {
        let components = output.components(separatedBy: ScriptTokens.fieldSeparator)
        guard components.count > isPlayingField else { return nil }
        return AppState(
            title: components[0].trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: components[1].trimmingCharacters(in: .whitespacesAndNewlines),
            isPlaying: components[isPlayingField].trimmingCharacters(in: .whitespacesAndNewlines) == "true",
            error: nil
        )
    }

    /// Wraps a track-change action so the status read that follows doesn't race
    /// the player's own transition (Music and Spotify's `next track` /
    /// `previous track` return before `current track` updates): capture the
    /// current track id, run the action, then poll (bounded, ~1 s max) until
    /// the id changes — or playback stops — before falling through to the
    /// status read. Exits the instant the player advances (usually well under
    /// 200 ms). The only case that waits out the full ~1 s is a
    /// single-track/repeat-one context where the track can never change — and
    /// there the title is identical anyway, so it's invisible.
    func waitForTrackChangeScript(around actionScript: String) -> String {
        """
        set previousTrackId to missing value
        try
            set previousTrackId to id of current track
        end try
        \(actionScript)
        repeat 20 times
            try
                if player state is stopped then exit repeat
                if id of current track is not previousTrackId then exit repeat
            end try
            delay 0.05
        end repeat
        """
    }

    /// Wraps a play/pause action so the status read reflects the new state.
    /// Some players (notably Spotify) update `player state` a beat after
    /// `playpause` returns, so reading immediately yields the pre-toggle value.
    /// Capture the state, toggle, then poll (bounded, ~1 s) until it flips
    /// before falling through to the status read. Exits at once on players that
    /// update synchronously, and rides out the extra lag when the app's
    /// scripting interface is still cold right after connecting.
    func waitForPlayStateChangeScript(around actionScript: String) -> String {
        """
        set previousPlayerState to missing value
        try
            set previousPlayerState to player state
        end try
        \(actionScript)
        repeat 20 times
            try
                if player state is not previousPlayerState then exit repeat
            end try
            delay 0.05
        end repeat
        """
    }

    /// System Events fragments shared by the UI-scripted players (IINA/mpv):
    /// capture-and-foreground, and the matching restore. The *conditions* stay
    /// per-platform — IINA must foreground even for status reads (menu-bar
    /// access) while mpv only foregrounds to deliver keystrokes — but the
    /// mechanics (save name, set frontmost, settle delay, restore) live here so
    /// a focus-handling fix reaches both.
    func captureAndForegroundProcessFragment(_ processName: String) -> String {
        """
        set previousFrontmostApp to name of first application process whose frontmost is true
        set frontmost of process "\(processName)" to true
        delay 0.1
        """
    }

    func restorePreviousFrontmostFragment() -> String {
        """
        if shouldRestoreOrder and previousFrontmostApp is not null then
            set frontmost of process previousFrontmostApp to true
        end if
        """
    }

    var menuActions: [ActionConfig] {
        [
            ActionConfig(action: .closeApp(name), icon: "xmark.circle.fill"),
        ]
    }

    /// Combined status script: checks if the application process exists and, if so,
    /// executes the platformʼs `fetchState()` AppleScript.  If not running we
    /// return the `ScriptTokens.notRunning` sentinel that `AppController`
    /// matches exactly.  Wrapping everything in a single
    /// `tell application \"System Events\"` block keeps the entire script
    /// within one top-level tell as required by the remote interactive shell.
    /// Platforms whose `fetchState()` already self-guards skip the wrapper —
    /// System Events process enumeration is slow, and running it twice per
    /// poll delays everything queued behind it on the serialized channel.
    func combinedStatusScript() -> String {
        guard !fetchStateIsSelfGuarding else { return fetchState() }
        return """
        tell application \"System Events\"
            if (count of (processes where name is \"\(name)\")) > 0 then
                \(fetchState())
            else
                return \"\(ScriptTokens.notRunning)\"
            end if
        end tell
        """
    }

    /// Default implementation for handling menu actions that need status updates after execution
    func executeMenuActionWithStatus(_ action: AppAction) -> String {
        switch action {
        case .closeApp:
            return """
            tell application "System Events"
                tell application "\(name)" to quit
                delay 1.5
                if (count of (processes where name is "\(name)")) = 0 then
                    return "\(ScriptTokens.notRunning)"
                end if
            end tell
            """
        default:
            return executeAction(action)
        }
    }
} 
