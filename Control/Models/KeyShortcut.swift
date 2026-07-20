import Foundation

/// A modifier that can join a key in a shortcut. Fn/Globe is absent because
/// System Events can't synthesize it. Case order is ⌃⌥⇧⌘ — Apple's canonical
/// display order — and everything derived (caps, captions, spoken names,
/// scripts) lists modifiers in this order.
enum KeyModifier: String, Codable, CaseIterable, Equatable {
    case control, option, shift, command

    /// The cap glyph: "⌃⌥⇧⌘".
    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    /// The caption name ("Ctrl + C") — abbreviated to fit a tile's caption.
    var shortName: String {
        switch self {
        case .control: return "Ctrl"
        case .option: return "Opt"
        case .shift: return "Shift"
        case .command: return "Cmd"
        }
    }

    /// The spoken name for VoiceOver and Voice Control ("Command Z").
    var spokenName: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        }
    }

    /// The System Events `using {…}` list member.
    var appleScriptFlag: String {
        "\(rawValue) down"
    }
}

/// One keystroke of a shortcut: a key plus the modifiers held with it.
struct KeyPress: Equatable {
    let key: RemoteKey
    /// Always kept in canonical (`KeyModifier.allCases`) order.
    let modifiers: [KeyModifier]

    init(key: RemoteKey, modifiers: [KeyModifier]) {
        self.key = key
        self.modifiers = KeyModifier.allCases.filter(modifiers.contains)
    }

    /// The cap fragment: "⌘Z", "⌃⌘F", "⇧↑".
    var capText: String {
        modifiers.map(\.symbol).joined() + key.chordCap
    }

    /// The caption fragment: "Cmd + Z".
    var captionText: String {
        (modifiers.map(\.shortName) + [key.label]).joined(separator: " + ")
    }

    /// The spoken fragment: "Command Z".
    var spokenText: String {
        (modifiers.map(\.spokenName) + [key.label]).joined(separator: " ")
    }
}

extension KeyPress: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .key)
        guard let key = RemoteKey.withID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "Unknown key id \(id)")
        }
        // An unknown modifier string fails the whole press (KeyModifier's
        // rawValue decode throws): sending a chord with a silently dropped
        // modifier would press something the user never configured.
        let modifiers = try container.decodeIfPresent([KeyModifier].self, forKey: .modifiers) ?? []
        self.init(key: key, modifiers: modifiers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.id, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

/// A shortcut the pad can send: one or more modified presses. The first UI
/// only builds single chords (⌘Z); the array is the seam for later sequences
/// (⌘K ⌘S) without a stored-data migration. `name` is reserved for future
/// custom naming ("Undo") — today the UI always spells the chord.
struct KeyShortcut: Equatable, Codable {
    var name: String?
    var presses: [KeyPress]

    /// The cap: presses joined ("⌘Z"; a future sequence reads "⌘K ⌘S").
    var capText: String {
        presses.map(\.capText).joined(separator: " ")
    }

    /// The caption under the cap: "Cmd + Z"; sequences join with commas.
    var captionText: String {
        presses.map(\.captionText).joined(separator: ", ")
    }

    /// Spoken form for VoiceOver/Voice Control: the name once names exist,
    /// else "Command Z".
    var spokenText: String {
        name ?? presses.map(\.spokenText).joined(separator: ", ")
    }

    /// A stable identity derived from content, for action ids and dedupe.
    var contentID: String {
        presses.map { press in
            (press.modifiers.map(\.rawValue) + [press.key.id]).joined(separator: "+")
        }.joined(separator: "_")
    }
}

extension KeyShortcut {
    private static func chord(_ name: String, _ modifiers: [KeyModifier], _ keyID: String) -> KeyShortcut {
        // Catalog constants under test; a bad id is a programmer error.
        KeyShortcut(name: name, presses: [KeyPress(key: RemoteKey.withID(keyID)!, modifiers: modifiers)])
    }

    /// The preconfigured shortcuts the picker ships with. Names are carried
    /// for the future naming UI; today's captions still spell the chord.
    static let presets: [KeyShortcut] = [
        chord("Undo", [.command], "z"),
        chord("Redo", [.shift, .command], "z"),
        chord("Copy", [.command], "c"),
        chord("Paste", [.command], "v"),
        chord("Fullscreen", [.control, .command], "f"),
    ]
}
