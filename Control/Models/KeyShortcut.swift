import Foundation

/// Fn/Globe is absent because System Events can't synthesize it. Case order is
/// Apple's canonical ⌃⌥⇧⌘, and everything derived below follows it.
enum KeyModifier: String, Codable, CaseIterable, Equatable {
    case control, option, shift, command

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    /// Abbreviated to fit a tile's caption.
    var shortName: String {
        switch self {
        case .control: return "Ctrl"
        case .option: return "Opt"
        case .shift: return "Shift"
        case .command: return "Cmd"
        }
    }

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

struct KeyPress: Equatable {
    let key: RemoteKey
    /// Always kept in canonical (`KeyModifier.allCases`) order.
    let modifiers: [KeyModifier]

    init(key: RemoteKey, modifiers: [KeyModifier]) {
        self.key = key
        self.modifiers = KeyModifier.allCases.filter(modifiers.contains)
    }

    var capText: String {
        modifiers.map(\.symbol).joined() + key.chordCap
    }

    var captionText: String {
        (modifiers.map(\.shortName) + [key.label]).joined(separator: " + ")
    }

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
        // Throws on an unknown modifier: a chord with one silently dropped
        // would press something the user never configured.
        let modifiers = try container.decodeIfPresent([KeyModifier].self, forKey: .modifiers) ?? []
        self.init(key: key, modifiers: modifiers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.id, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

/// One or more modified presses. The array is the seam for later sequences
/// (⌘K ⌘S) without a stored-data migration; the UI only builds single chords.
/// `name` is reserved for future custom naming; nothing reads it today.
struct KeyShortcut: Equatable, Codable {
    var name: String?
    var presses: [KeyPress]

    var capText: String {
        presses.map(\.capText).joined(separator: " ")
    }

    var captionText: String {
        presses.map(\.captionText).joined(separator: ", ")
    }

    /// Spoken form for VoiceOver/Voice Control: "Command Z". The chord, never
    /// `name` — only what's on the cap is sayable.
    var spokenText: String {
        presses.map(\.spokenText).joined(separator: ", ")
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
        KeyShortcut(name: name, presses: [KeyPress(key: RemoteKey.withID(keyID)!, modifiers: modifiers)])
    }

    /// Names are carried for the future naming UI.
    static let presets: [KeyShortcut] = [
        chord("Undo", [.command], "z"),
        chord("Redo", [.shift, .command], "z"),
        chord("Copy", [.command], "c"),
        chord("Paste", [.command], "v"),
        chord("Fullscreen", [.control, .command], "f"),
    ]
}
