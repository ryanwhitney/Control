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
/// question this page raises — where are my key presses about to land.
///
/// No subtitle for now. The front window's title used to ride along there (and on
/// macOS that's already the active browser tab's name, so it needed no per-browser
/// scripting) — but reading it costs a ~42 ms `name of front window` AX call
/// against the ~13 ms the rest of this takes, and it was pulled while the page's
/// responsiveness is being tuned.
struct KeyboardApp: AppPlatform {
    let id = "keyboard"
    let name = "Keyboard"
    let defaultEnabled = true
    let controlStyle: ControlStyle = .keyPad
    // Deliberately NOT `checksStatusOnlyWhenVisible`: that flag exists for pages
    // whose status read foregrounds a Mac app, and this one never does. Opting in
    // only bought the page ControlView's 350 ms settle delay and exclusion from
    // background prefetch, so it alone started cold and showed "Loading…" on every
    // visit while every other tab was pre-filled. The read is no more expensive
    // than the process-existence check every other platform's status already runs.

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
    ///
    /// Every step here was chosen by measurement (~55 ms, down from ~231 ms for
    /// the obvious version). Findings worth not re-deriving:
    ///
    ///  * `first application process whose frontmost is true` costs ~157 ms, and a
    ///    reference it returns re-runs that filter on *every* property access
    ///    (~50 ms a touch) — so the natural "save the process, read three
    ///    properties off it" shape pays for the search four times over. Asking for
    ///    the frontmost app's bundle path costs ~13 ms instead.
    ///  * `path to frontmost application` reports the console session's real
    ///    frontmost app over SSH — verified from an SSH shell with Safari front.
    ///    Coerce it `as text` and parse; **never** `as alias`, which errors on
    ///    Cryptex-resident apps (Safari lives at `Preboot:Cryptexes:App:…`).
    ///
    /// Kept to one top-level tell: the remote `osascript -i` evaluates line by
    /// line, and every risky step is wrapped so a mid-script error can't fail the
    /// whole command. The System Events search remains as a fallback — it's the
    /// slow path, but it's the one that's been proven longest.
    ///
    /// The middle field is the (now unused) subtitle: the shared parse needs three
    /// fields to read the third, so it stays empty rather than absent.
    private func statusScript() -> String {
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "System Events"
            set frontApp to ""
            try
                set appPath to path to frontmost application as text
                set savedDelims to AppleScript's text item delimiters
                set AppleScript's text item delimiters to ":"
                set pathParts to text items of appPath
                set AppleScript's text item delimiters to savedDelims
                repeat with i from (count of pathParts) to 1 by -1
                    set segment to item i of pathParts
                    if segment is not "" then
                        if segment ends with ".app" then set segment to text 1 thru -5 of segment
                        set frontApp to segment
                        exit repeat
                    end if
                end repeat
            end try
            if frontApp is "" then
                try
                    set frontApp to name of first application process whose frontmost is true
                end try
            end if
            if frontApp is "" then
                return "No app in front\(sep)\(sep)false"
            end if
            return frontApp & "\(sep)\(sep)false"
        end tell
        """
    }

    func fetchState() -> String { statusScript() }

    /// A complete, self-contained script (like TV's key actions, not the injected
    /// fragment QuickTime/mpv return) — a key press sends exactly this and nothing
    /// else. It's a single System Events statement, ~0.4 ms of work, which is the
    /// whole point: see `AppController.executeActionWithoutStatus`.
    func executeAction(_ action: AppAction) -> String {
        guard case .key(let key) = action else { return "" }
        return """
        tell application "System Events"
            key code \(key.keyCode) -- \(key.label.lowercased())
        end tell
        """
    }

    /// Only used if something routes a key through the status-bundling path; the
    /// pad itself doesn't. Concatenated rather than injected, since
    /// `executeAction` is now its own tell block.
    func actionWithStatus(_ action: AppAction) -> String {
        executeAction(action) + "\n" + statusScript()
    }

    /// Nothing here plays, so drop the boolean the shared parse always fills in
    /// rather than let it read downstream as "paused".
    func parseState(_ output: String) -> AppState {
        guard var state = parseSeparatedState(output) else {
            return AppState(title: "", subtitle: "", error: "Unable to parse status")
        }
        state.isPlaying = nil
        return state
    }
}
