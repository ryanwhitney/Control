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
    ///    lives at `Preboot:Cryptexes:App:…`). HFS text stores a displayed `/`
    ///    as `:`, so an app named "AC/DC Player" reads back truncated — accepted:
    ///    it's display-only, and `name of (path to …)` avoids it for ~10 ms more.
    ///
    /// `UI elements enabled` is the assistive-access check the pad needs and this
    /// read doesn't — here so the readout and a key press can't disagree. It costs
    /// ~10 ms against the read's ~13 ms, so the controller drops it once the grant
    /// is confirmed and puts it back if a press is ever refused.
    ///
    /// `UI elements enabled` never prompts, and with the guard returning early
    /// no key is ever sent, so macOS would never list sshd-keygen-wrapper under
    /// Accessibility. The prompting guard asks with `AXIsProcessTrustedWithOptions`
    /// instead, at top level: inside the tell, System Events would be the asker.
    ///
    /// Delimiters are saved *above* the `try` and restored in both paths: they're
    /// global to the interpreter, and Fast keeps one alive per channel, so an
    /// error between set and restore would leak ":" into every later command —
    /// and the next run would then read ":" as the value to restore.
    ///
    /// The empty middle field stands in for the absent subtitle: the shared parse
    /// needs three fields before it reads the third.
    private func statusScript(assistiveAccessGuard: AssistiveAccessGuard) -> String {
        let sep = ScriptTokens.fieldSeparator
        let denied = "return \"\(ScriptTokens.accessibilityRequired)\""
        var promptLine = ""
        var checkLine = ""
        switch assistiveAccessGuard {
        case .none:
            break
        case .check:
            checkLine = "\n    if not (UI elements enabled) then \(denied)"
        case .prompt:
            let js = "ObjC.import('ApplicationServices');"
                + "$.AXIsProcessTrustedWithOptions($({AXTrustedCheckOptionPrompt:true}))"
            promptLine = "if not (run script \"\(js)\" in \"JavaScript\") then \(denied)\n"
        }
        return """
        \(promptLine)tell application "System Events"\(checkLine)
            set frontApp to ""
            set savedDelims to AppleScript's text item delimiters
            try
                set appPath to path to frontmost application as text
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
                set AppleScript's text item delimiters to savedDelims
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

    private enum AssistiveAccessGuard {
        case none
        case check
        case prompt
    }

    func fetchState() -> String { statusScript(assistiveAccessGuard: .prompt) }

    /// Dropping the guard is the controller's call; see `assistiveAccessVerified`.
    func combinedStatusScript(assumingAssistiveAccess: Bool) -> String {
        statusScript(assistiveAccessGuard: assumingAssistiveAccess ? .none : .check)
    }

    /// Self-contained, not an injected fragment: a key press sends exactly this.
    /// One System Events statement per press, all inside the same tell.
    func executeAction(_ action: AppAction) -> String {
        let statements: [String]
        switch action {
        case .key(let key):
            statements = [pressStatement(for: key, modifiers: [])]
        case .shortcut(let shortcut):
            statements = shortcut.presses.map { pressStatement(for: $0.key, modifiers: $0.modifiers) }
        case .typing(let edits):
            // Top-level statements, not inside the tell: the Unicode path's
            // `run script` must run here, not be sent to System Events.
            return Self.typingStatements(for: edits).joined(separator: "\n")
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

    /// Past this, a statement is split: the streaming PTY runs in canonical
    /// mode, which silently truncates input lines near 1024 bytes.
    private static let maxTypingLineLength = 400

    /// `CGEventKeyboardSetUnicodeString` carries at most 20 UTF-16 units.
    private static let maxUnitsPerEvent = 20

    /// Deletes and caret moves are key presses, repeated in a loop when there
    /// are several so the line stays short.
    static func typingStatements(for edits: [TypingEdit]) -> [String] {
        edits.flatMap { edit -> [String] in
            switch edit {
            case .text(let text): return textStatements(for: text)
            case .deleteBackward(let count): return repeatedKey(51, "delete", count)
            case .moveLeft(let count): return repeatedKey(123, "left", count)
            case .moveRight(let count): return repeatedKey(124, "right", count)
            }
        }
    }

    private static func repeatedKey(_ code: Int, _ name: String, _ count: Int) -> [String] {
        switch count {
        case ..<1: return []
        case 1: return [systemEvents("key code \(code) -- \(name)")]
        default: return ["tell application \"System Events\"\nrepeat \(count) times\nkey code \(code) -- \(name)\nend repeat\nend tell"]
        }
    }

    /// Return and tab go as key codes, printable ASCII through
    /// `keystroke` so the Mac's layout resolves it. Anything else — emoji,
    /// accents, other scripts — `keystroke` can't type: it looks each
    /// character up on the layout and sends key code 0 ("a") for a miss. Those
    /// go as Unicode key events instead (see `unicodeStatement`). Control
    /// characters are dropped: in canonical mode the PTY would act on them.
    ///
    /// Each statement is top-level and one line, so the script stays ASCII and
    /// every line stays short.
    static func textStatements(for text: String) -> [String] {
        var statements: [String] = []
        var literal = ""
        var chunks: [[UInt16]] = []
        var chunkTextLength = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            statements.append(systemEvents("keystroke \"\(literal)\""))
            literal = ""
        }
        func flushUnicode() {
            guard !chunks.isEmpty else { return }
            statements.append(unicodeStatement(chunks))
            chunks = []
            chunkTextLength = 0
        }
        func keyCode(_ code: Int, _ name: String) {
            flushLiteral()
            flushUnicode()
            statements.append(systemEvents("key code \(code) -- \(name)"))
        }

        for character in text {
            switch character {
            case "\r\n", "\r", "\n":
                keyCode(36, "return")
            case "\t":
                keyCode(48, "tab")
            default:
                let scalars = character.unicodeScalars
                if scalars.count == 1, let scalar = scalars.first, (0x20...0x7E).contains(scalar.value) {
                    flushUnicode()
                    literal += scalar == "\"" || scalar == "\\" ? "\\\(scalar)" : String(scalar)
                    if literal.count >= maxTypingLineLength { flushLiteral() }
                } else {
                    let units = String(String.UnicodeScalarView(scalars.filter(isTypeable))).utf16
                    guard !units.isEmpty else { continue }
                    flushLiteral()
                    // A grapheme never splits across events: half an emoji
                    // would type as garbage.
                    if let last = chunks.last, last.count + units.count <= maxUnitsPerEvent {
                        chunks[chunks.count - 1] += units
                    } else {
                        chunks.append(Array(units))
                    }
                    chunkTextLength += units.map { String($0).count + 1 }.reduce(0, +)
                    if chunkTextLength >= maxTypingLineLength { flushUnicode() }
                }
            }
        }
        flushLiteral()
        flushUnicode()
        return statements
    }

    private static func isTypeable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0xA0 || (0x20...0x7E).contains(scalar.value)
    }

    private static func systemEvents(_ statement: String) -> String {
        "tell application \"System Events\" to \(statement)"
    }

    /// Posts each chunk as a key down/up pair carrying the text itself, which
    /// apps insert as typed. JavaScript because AppleScript can't call
    /// C functions; run in this interpreter, so the posting process is the one
    /// Accessibility was granted to. The buffer parameter is rebound as
    /// `void *`: the bridge won't pass `NSData.bytes` as `UniChar *`, nor a JS
    /// string or array. Code units go as numbers, so the source needs no
    /// escaping, and single quotes only, so it nests in the AppleScript literal.
    /// In a `try`: a failure here must not fail the typing around it.
    private static func unicodeStatement(_ chunks: [[UInt16]]) -> String {
        let data = chunks.map { "[" + $0.map(String.init).joined(separator: ",") + "]" }.joined(separator: ",")
        let js = "ObjC.import('Cocoa');"
            + "ObjC.bindFunction('CGEventKeyboardSetUnicodeString',['void',['void *','unsigned long','void *']]);"
            + "[\(data)].forEach(function(c){"
            + "var d=$(String.fromCharCode.apply(null,c)).dataUsingEncoding($.NSUTF16LittleEndianStringEncoding);"
            + "[true,false].forEach(function(k){"
            + "var e=$.CGEventCreateKeyboardEvent(null,0,k);"
            + "$.CGEventKeyboardSetUnicodeString(e,c.length,d.bytes);"
            + "$.CGEventPost(0,e)})})"
        return "try\nrun script \"\(js)\" in \"JavaScript\"\nend try"
    }

    /// Unused by the pad. Concatenated rather than injected, since
    /// `executeAction` is a standalone tell block.
    func actionWithStatus(_ action: AppAction) -> String {
        executeAction(action) + "\n" + statusScript(assistiveAccessGuard: .check)
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
