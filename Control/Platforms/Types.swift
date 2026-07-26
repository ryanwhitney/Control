import Foundation
import SwiftUI

enum ControlStyle: Equatable {
    case transport
    case keyPad
}

enum AppAction: Identifiable, Equatable {
    case skipForward(Int)
    case skipBackward(Int)
    case previousTrack
    case nextTrack
    case playPauseToggle
    case closeApp(String)
    case key(RemoteKey)
    case shortcut(KeyShortcut)

    var id: String {
        switch self {
        case .skipForward(let seconds): return "forward\(seconds)"
        case .skipBackward(let seconds): return "backward\(seconds)"
        case .previousTrack: return "previousTrack"
        case .nextTrack: return "nextTrack"
        case .playPauseToggle: return "playPauseToggle"
        case .closeApp: return "closeApp"
        case .key(let key): return "key_\(key.id)"
        case .shortcut(let shortcut): return "shortcut_\(shortcut.contentID)"
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
        case .key(let key):
            return key.label
        case .shortcut(let shortcut):
            return shortcut.spokenText
        }
    }

    /// What the debug log may say. Key presses report only that a key was sent:
    /// the pad targets whatever is frontmost on the Mac, so the key itself can
    /// be someone's password, and the logs are shareable.
    var logDescription: String {
        switch self {
        case .key: return "key press"
        case .shortcut: return "shortcut"
        default: return label
        }
    }

    /// Voice Control names — shorter than the descriptive VoiceOver labels.
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
        case .key(let key):
            return key.inputLabels
        case .shortcut(let shortcut):
            return [shortcut.spokenText]
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
        // Closures can't be compared.
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

/// Which macOS grant is missing. Automation lets Control drive an app;
/// Accessibility lets it send key presses. Separate switches, separate panes.
enum PermissionKind: Identifiable, Equatable {
    case automation
    case accessibility

    var id: Self { self }
}

struct AppState: Equatable {
    var title: String
    var subtitle: String
    var isPlaying: Bool?
    var error: String?
    /// Set only on a missing-permission readout, so the page can offer the
    /// instructions for the grant that's actually missing.
    var permissionKind: PermissionKind?
}

protocol AppPlatform: Identifiable {
    var id: String { get }
    var name: String { get }
    /// One-liner under the name in Choose Apps; nil for apps whose name says it.
    var listDescription: String? { get }
    var defaultEnabled: Bool { get }
    var checksStatusOnlyWhenVisible: Bool { get }
    var minActionInterval: TimeInterval { get }
    var fetchStateIsSelfGuarding: Bool { get }
    var targetsFrontmostApp: Bool { get }
    var experimental: Bool { get }
    var reasonForExperimental: String { get }
    var controlStyle: ControlStyle { get }
    var supportedActions: [ActionConfig] { get }
    var menuActions: [ActionConfig] { get }
    
    func fetchState() -> String
    func combinedStatusScript(assumingAssistiveAccess: Bool) -> String
    func executeAction(_ action: AppAction) -> String
    func executeMenuActionWithStatus(_ action: AppAction) -> String
    func parseState(_ output: String) -> AppState
    func actionWithStatus(_ action: AppAction) -> String
}

extension AppPlatform {
    var experimental: Bool { false }
    var reasonForExperimental: String { "" }
    var listDescription: String? { nil }

    var controlStyle: ControlStyle { .transport }

    /// True for apps with no AppleScript status (IINA, mpv): reading theirs
    /// foregrounds the Mac app, so the bulk sweep skips them and they refresh
    /// only when their own tab is on screen.
    var checksStatusOnlyWhenVisible: Bool { false }

    /// 0 disables rate limiting. Platforms whose actions can flood a channel
    /// (TV's key-code skips) override it.
    var minActionInterval: TimeInterval { 0 }

    /// True when `fetchState()` guards the app-not-running case itself, so
    /// `combinedStatusScript()` can skip a second process enumeration per poll.
    var fetchStateIsSelfGuarding: Bool { false }

    /// True for platforms acting on whatever is frontmost: activating an app
    /// would change that, so the permission check skips its activate step.
    var targetsFrontmostApp: Bool { false }

    /// The shared separated shape below. Platforms that post-process (IINA,
    /// Safari) or read a different field (VLC) override this.
    func parseState(_ output: String) -> AppState {
        parseSeparatedState(output)
            ?? AppState(title: "", subtitle: "", error: "Unable to parse status")
    }

    /// The shared "title | subtitle | … | isPlaying" shape. nil when the output
    /// is short, so platforms can supply their own fallback. `isPlayingField`
    /// names the boolean's index for scripts with extra fields (VLC).
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

    /// Music and Spotify's `next track` returns before `current track` updates,
    /// so poll (bounded, ~1 s) for the id to change before reading status. Only
    /// a repeat-one context waits out the full second, where the title is
    /// identical anyway.
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

    /// Spotify updates `player state` a beat after `playpause` returns, so
    /// reading immediately yields the pre-toggle value. Polls (bounded, ~1 s)
    /// for the flip; exits at once on players that update synchronously.
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

    /// Shared by the UI-scripted players (IINA/mpv). The *conditions* stay
    /// per-platform; the mechanics live here so a focus fix reaches both.
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

    /// `fetchState()` behind a process-exists check, all inside one top-level
    /// tell as the remote interactive shell requires. Self-guarding platforms
    /// skip the wrapper: process enumeration is slow, and everything queued
    /// behind it on the serialized channel waits.
    /// Only platforms whose script carries an assistive-access guard implement
    /// this; for everyone else the flag has nothing to drop.
    func combinedStatusScript(assumingAssistiveAccess: Bool) -> String {
        combinedStatusScript()
    }

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
