import Foundation

/// Sends plain key presses to whatever app is frontmost on the Mac — nothing to
/// pick, nothing brought forward.
///
/// System Events delivers `key code` to the frontmost application regardless of
/// any enclosing `tell process`, which every other key-driven platform here has
/// to work around by activating its app first (TVApp/IINAApp/MPVApp). This
/// platform leans on that behaviour instead of fighting it: someone who started
/// something on the Mac and walked away left the app they care about in front,
/// so "frontmost" *is* the target. That also means no focus to capture, settle
/// or restore, so the script stays a single System Events tell.
///
/// The trade is that it's blind: there's no dictionary to read playback from.
/// Status is the frontmost app's *name* instead, so the readout answers the only
/// question this page raises — where are my key presses about to land. The front
/// window's title rides along as the subtitle, which on every mainstream macOS
/// browser is already the active tab's name — no per-browser scripting needed
/// (see `windowSubtitle`).
struct KeyboardApp: AppPlatform {
    let id = "keyboard"
    let name = "Keyboard"
    let defaultEnabled = true
    let controlStyle: ControlStyle = .keyPad
    /// Which app is frontmost changes on the Mac's schedule, not ours, and only
    /// matters while this page is on screen — so it's kept out of the background
    /// sweep. Unlike IINA/mpv the reason isn't focus stealing: this read never
    /// brings anything forward.
    let checksStatusOnlyWhenVisible = true

    var supportedActions: [ActionConfig] {
        RemoteKey.allCases.map { .key($0) }
    }

    /// No app of our own to quit — the inherited "Close Keyboard" item would be
    /// nonsense.
    var menuActions: [ActionConfig] { [] }

    /// `fetchState()` guards itself, and there's no "Keyboard" process for
    /// `combinedStatusScript()`'s wrapper to find, so it has to skip it.
    var fetchStateIsSelfGuarding: Bool { true }

    /// Reads the frontmost process's name and its front window's title. Neither
    /// read brings anything forward, and every risky step is wrapped in `try`:
    /// an app with no windows, or one whose window has no title, must degrade to
    /// a blank subtitle rather than fail the command (the streaming parser fails
    /// the whole command on any mid-script error).
    private func statusScript(precededBy actionScript: String = "") -> String {
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "System Events"
            \(actionScript)
            set frontApp to ""
            set windowTitle to ""
            try
                set frontProcess to first application process whose frontmost is true
                set frontApp to name of frontProcess
                -- Prefer the display name: several apps carry an unfriendly
                -- process name ("sublime_text" vs "Sublime Text").
                try
                    set shownName to displayed name of frontProcess
                    if shownName is not missing value and shownName is not "" then
                        set frontApp to shownName
                    end if
                end try
                try
                    set frontTitle to name of front window of frontProcess
                    if frontTitle is not missing value then set windowTitle to frontTitle
                end try
            end try
            if frontApp is "" then
                return "No app in front\(sep)\(sep)false"
            end if
            return frontApp & "\(sep)" & windowTitle & "\(sep)false"
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    /// Just the key line: injected at the top of `statusScript`'s System Events
    /// tell block, so no bare `return` here — it would exit before the status
    /// read and leave the readout stale.
    func executeAction(_ action: AppAction) -> String {
        guard case .key(let key) = action else { return "" }
        return "key code \(key.keyCode) -- \(key.label.lowercased())"
    }

    func actionWithStatus(_ action: AppAction) -> String {
        statusScript(precededBy: executeAction(action))
    }

    /// Nothing here plays, so drop the boolean the shared parse always fills in
    /// rather than let it read downstream as "paused", and drop a window title
    /// that only repeats the app name above it.
    func parseState(_ output: String) -> AppState {
        guard var state = parseSeparatedState(output) else {
            return AppState(title: "", subtitle: "", error: "Unable to parse status")
        }
        state.isPlaying = nil
        state.subtitle = Self.windowSubtitle(state.subtitle, appName: state.title)
        return state
    }

    /// The front window's title, unless the app name already says it — "Calendar
    /// / Calendar" is noise, and so is a title the app name wholly contains
    /// ("Chrome" under "Google Chrome"). A *longer* title stays even when it
    /// contains the app name, because the remainder is real information
    /// ("Activity Monitor – All Processes", mpv's "No file - mpv").
    ///
    /// This is where a browser's active tab shows up: on macOS, Safari (verified),
    /// Chromium and Firefox all title the window after the current page, so the
    /// generic AX read already gets the tab name. Reading it from a browser's
    /// AppleScript dictionary instead would need per-browser Automation consent —
    /// prompted on the very Mac the user has walked away from — for no gain.
    static func windowSubtitle(_ windowTitle: String, appName: String) -> String {
        let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !app.isEmpty else { return "" }
        // Covers both "identical to" and "contained within" in one check.
        return app.localizedCaseInsensitiveContains(title) ? "" : title
    }
}
