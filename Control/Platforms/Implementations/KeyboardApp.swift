import Foundation

/// Sends key presses to whatever app is frontmost on the Mac. System Events
/// delivers `key code` there regardless of any enclosing `tell process`, so
/// unlike TVApp/IINAApp/MPVApp this one never activates an app first — there's
/// no focus to capture or restore.
///
/// It has no dictionary to read playback from, so status is the frontmost app's
/// name: where the next key press will land.
struct KeyboardApp: AppPlatform {
    let id = "keyboard"
    let name = "Keyboard"
    /// The one platform whose name alone doesn't say what it drives.
    let listDescription: String? = "Works with whatever app is foregrounded on your Mac."
    let defaultEnabled = true
    let controlStyle: ControlStyle = .keyPad
    // Deliberately NOT `checksStatusOnlyWhenVisible`: that's for reads that
    // foreground a Mac app, which this one never does.

    /// Empty on purpose: an action list feeds the transport row, which the
    /// keyPad style never renders. A flat list can't say which key goes where.
    var supportedActions: [ActionConfig] { [] }

    /// No app of our own to quit.
    var menuActions: [ActionConfig] { [] }

    /// There's no "Keyboard" process for the wrapper to find.
    var fetchStateIsSelfGuarding: Bool { true }

    /// No app to bring forward, so the permission check must not activate one.
    var targetsFrontmostApp: Bool { true }

    /// `errAEEventNotPermitted` — the error a denied Automation prompt raises.
    private static let notAuthorizedErrorNumber = -1743

    /// Reads the frontmost app's name from its bundle path. Every risky step is
    /// wrapped in `try` so a mid-script error degrades to a blank field instead of
    /// failing the command — except a denied Automation permission, re-raised to
    /// reach the shared "Not authorized to send Apple events" check.
    ///
    /// Chosen by measurement (~55 ms vs ~231 ms):
    ///
    ///  * `first application process whose frontmost is true` costs ~157 ms and
    ///    re-runs that filter on every property access, so it's only a fallback.
    ///  * `path to frontmost application` costs ~13 ms. Coerce `as text`;
    ///    **never** `as alias`, which errors on Cryptex-resident apps (Safari
    ///    lives at `Preboot:Cryptexes:App:…`).
    ///
    /// `UI elements enabled` is the assistive-access check the pad needs and this
    /// read doesn't — here so the readout and a key press can't disagree.
    ///
    /// The empty middle field stands in for the absent subtitle: the shared parse
    /// needs three fields before it reads the third.
    private func statusScript() -> String {
        let sep = ScriptTokens.fieldSeparator
        return """
        tell application "System Events"
            if not (UI elements enabled) then return "\(ScriptTokens.accessibilityRequired)"
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
            on error errorMessage number errorNumber
                if errorNumber is \(Self.notAuthorizedErrorNumber) then error errorMessage number errorNumber
            end try
            if frontApp is "" then
                try
                    set frontApp to name of first application process whose frontmost is true
                on error errorMessage number errorNumber
                    if errorNumber is \(Self.notAuthorizedErrorNumber) then error errorMessage number errorNumber
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

    /// Self-contained, not an injected fragment: a key press sends exactly this.
    /// One System Events statement per press, all inside the same tell.
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

    /// `keystroke` for character keys so the Mac's own layout resolves them —
    /// "a" types a on AZERTY too, where `key code 0` would type q. Backslash is
    /// the one catalog character an AppleScript literal needs escaped.
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

    /// Unused by the pad. Concatenated rather than injected, since
    /// `executeAction` is a standalone tell block.
    func actionWithStatus(_ action: AppAction) -> String {
        executeAction(action) + "\n" + statusScript()
    }

    /// Nothing here plays; the shared parse's boolean would read as "paused".
    func parseState(_ output: String) -> AppState {
        guard var state = parseSeparatedState(output) else {
            return AppState(title: "", subtitle: "", error: "Unable to parse status")
        }
        state.isPlaying = nil
        return state
    }
}
