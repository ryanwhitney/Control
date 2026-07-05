import Foundation
import SwiftUI

enum AppAction: Identifiable, Equatable {
    case skipForward(Int)
    case skipBackward(Int)
    case previousTrack
    case nextTrack
    case playPauseToggle
    case updateStatus
    case closeApp(String)
    
    var id: String {
        switch self {
        case .skipForward(let seconds): return "forward\(seconds)"
        case .skipBackward(let seconds): return "backward\(seconds)"
        case .previousTrack: return "previousTrack"
        case .nextTrack: return "nextTrack"
        case .playPauseToggle: return "playPauseToggle"
        case .updateStatus: return "updateStatus"
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
        case .updateStatus:
            return "Refresh"
        case .closeApp(let appName):
            return "Close \(appName)"
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
    var experimental: Bool { get }
    var reasonForExperimental: String { get }
    var supportedActions: [ActionConfig] { get }
    var menuActions: [ActionConfig] { get }
    
    func fetchState() -> String
    func executeAction(_ action: AppAction) -> String
    func executeMenuActionWithStatus(_ action: AppAction) -> String
    func parseState(_ output: String) -> AppState
    func isRunningScript() -> String
    func isInstalledScript() -> String
    func activateScript() -> String
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

    var menuActions: [ActionConfig] {
        [
            ActionConfig(action: .closeApp(name), icon: "xmark.circle.fill"),
        ]
    }
    
    func isInstalledScript() -> String {
        let appPath = "/Applications/\(name).app"
        return """
        tell application "System Events"
            if exists disk item "\(appPath)" then
                return "true"
            else
                return "false"
            end if
        end tell
        """
    }
    
    func activateScript() -> String {
        return """
        tell application "\(name)" to activate
        """
    }
    
    /// Combined status script: checks if the application process exists and, if so,
    /// executes the platformʼs `fetchState()` AppleScript.  If not running we
    /// simply return the sentinel string "NOT_RUNNING".  Wrapping everything in
    /// a single `tell application \"System Events\"` block keeps the entire
    /// script within one top-level tell as required by the remote interactive
    /// shell.
    func combinedStatusScript() -> String {
        return """
        tell application \"System Events\"
            if (count of (processes where name is \"\(name)\")) > 0 then
                \(fetchState())
            else
                return \"NOT_RUNNING\"
            end if
        end tell
        """
    }
    
    /// Default implementation for handling menu actions that need status updates after execution
    func executeMenuActionWithStatus(_ action: AppAction) -> String {
        switch action {
//        case .updateStatus:
//            return fetchState()
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
