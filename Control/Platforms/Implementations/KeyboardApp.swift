import Foundation

/// Sends plain key presses to whatever app is frontmost on the Mac — nothing to
/// pick, nothing brought forward.
///
/// System Events delivers `key code` to the frontmost application regardless of
/// any enclosing `tell process`, so unlike the other key-driven platforms
/// (TVApp/IINAApp/MPVApp) this one never activates an app first: "frontmost" is
/// the target, so there's no focus to capture or restore and the script stays a
/// single System Events tell.
///
/// It's blind — no dictionary to read playback from — so status is the frontmost
/// app's name, answering the only question the page raises: where key presses
/// will land. No subtitle.
struct KeyboardApp: AppPlatform {
    let id = "keyboard"
    let name = "Keyboard"
    /// The one platform whose name alone doesn't say what it drives.
    let listDescription: String? = "Works with whatever app is foregrounded on your Mac."
    let defaultEnabled = true
    let controlStyle: ControlStyle = .keyPad
    // Deliberately NOT `checksStatusOnlyWhenVisible`: that flag is for pages whose
    // status read foregrounds a Mac app, which this one never does. Its read is no
    // more expensive than the process-existence check every platform already runs,
    // so it stays eligible for background prefetch and needs no settle delay.

    /// Empty on purpose: an action list only feeds the transport row, which
    /// the keyPad style never renders. The pad is positional and draws from
    /// the user's `KeyPadLayout` instead — a flat list can't say which key
    /// belongs in which cell.
    var supportedActions: [ActionConfig] { [] }

    /// No app of our own to quit — the inherited "Close Keyboard" item would be
    /// nonsense.
    var menuActions: [ActionConfig] { [] }

    /// `fetchState()` guards itself, and there's no "Keyboard" process for
    /// `combinedStatusScript()`'s wrapper to find, so it has to skip it.
    var fetchStateIsSelfGuarding: Bool { true }

    /// Reads the frontmost app's name from its bundle path. Every risky step is
    /// wrapped in `try` so a mid-script error degrades to a blank field rather
    /// than failing the command (the streaming parser fails on any mid-script
    /// error).
    ///
    /// Chosen by measurement (~55 ms vs ~231 ms for the obvious version):
    ///
    ///  * `first application process whose frontmost is true` costs ~157 ms, and
    ///    the reference it returns re-runs that filter on every property access
    ///    (~50 ms each). The frontmost app's bundle path costs ~13 ms, so it's the
    ///    primary path and the System Events search is only a fallback.
    ///  * `path to frontmost application` reports the console session's real
    ///    frontmost app over SSH. Coerce `as text` and parse; **never** `as alias`,
    ///    which errors on Cryptex-resident apps (Safari lives at
    ///    `Preboot:Cryptexes:App:…`).
    ///
    /// The empty middle field stands in for the absent subtitle: the shared parse
    /// needs three fields before it reads the third.
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
    /// fragment QuickTime/mpv return): a key press sends exactly this. A plain key
    /// is a single System Events statement (~0.4 ms — see
    /// `AppController.executeActionWithoutStatus`); a shortcut is one statement per
    /// press, all inside the same tell.
    func executeAction(_ action: AppAction) -> String {
        let statements: [String]
        switch action {
        case .key(let key):
            statements = [pressStatement(for: key, modifiers: [])]
        case .shortcut(let shortcut):
            statements = shortcut.presses.map { pressStatement(for: $0.key, modifiers: $0.modifiers) }
        default:
            return ""
        }
        return """
        tell application "System Events"
            \(statements.joined(separator: "\n    "))
        end tell
        """
    }

    /// `key code` for the named keys; `keystroke` for character keys, so the
    /// Mac's own layout resolves the press — "a" types a on AZERTY too, where
    /// `key code 0` would type q. Backslash is the one catalog character an
    /// AppleScript string literal needs escaped. Modifiers ride along as a
    /// System Events `using {…}` list either way.
    private func pressStatement(for key: RemoteKey, modifiers: [KeyModifier]) -> String {
        let using = modifiers.isEmpty
            ? ""
            : " using {\(modifiers.map(\.appleScriptFlag).joined(separator: ", "))}"
        switch key.press {
        case .keyCode(let code):
            return "key code \(code)\(using) -- \(key.label.lowercased())"
        case .character(let character):
            return "keystroke \"\(character.replacingOccurrences(of: "\\", with: "\\\\"))\"\(using)"
        }
    }

    /// Only used if something routes a key through the status-bundling path; the
    /// pad itself doesn't. Concatenated rather than injected, since `executeAction`
    /// is a standalone tell block.
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
