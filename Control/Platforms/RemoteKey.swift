import Foundation

/// One key the generic pad can send. The catalog is the full unmodified Mac
/// keyboard — everything a key cap shows without holding anything, so ` but
/// not ~, letters but no ⌘. Modified presses (⌘Z…) are the planned shortcut
/// type layered on top in `PadCommand`, not extra keys here.
struct RemoteKey: Equatable, Identifiable {
    /// How the key cap draws.
    enum Glyph: Equatable {
        /// An SF Symbol. These keys also caption themselves with `label` in
        /// the editor — an arrow glyph alone doesn't name itself.
        case symbol(String)
        /// The character itself as text — the cap *is* the label ("A"), so no
        /// caption.
        case character(String)
    }

    /// What the Mac presses.
    enum Press: Equatable {
        /// A virtual key code, for the named keys no character reaches
        /// (arrows, escape…). Positional, but these sit in the same place on
        /// every layout.
        case keyCode(Int)
        /// A character for System Events' `keystroke`, which resolves the
        /// press against the Mac's own layout — "a" types a on AZERTY too,
        /// where `key code 0` would type q.
        case character(String)
    }

    let id: String
    /// Spoken/caption name: "Up", "A", "Comma".
    let label: String
    let glyph: Glyph
    let press: Press
    /// Alternative spoken names for Voice Control ("Tap up arrow").
    let inputLabels: [String]

    init(id: String, label: String, glyph: Glyph, press: Press, inputLabels: [String]? = nil) {
        self.id = id
        self.label = label
        self.glyph = glyph
        self.press = press
        self.inputLabels = inputLabels ?? [label]
    }
}

// MARK: - Catalog

extension RemoteKey {
    static let up = RemoteKey(id: "up", label: "Up", glyph: .symbol("arrowtriangle.up.fill"), press: .keyCode(126), inputLabels: ["Up", "Up arrow"])
    static let down = RemoteKey(id: "down", label: "Down", glyph: .symbol("arrowtriangle.down.fill"), press: .keyCode(125), inputLabels: ["Down", "Down arrow"])
    static let left = RemoteKey(id: "left", label: "Left", glyph: .symbol("arrowtriangle.left.fill"), press: .keyCode(123), inputLabels: ["Left", "Left arrow"])
    static let right = RemoteKey(id: "right", label: "Right", glyph: .symbol("arrowtriangle.right.fill"), press: .keyCode(124), inputLabels: ["Right", "Right arrow"])
    // Space is play/pause in most players, so Voice Control accepts those too —
    // it's what people will reach for on this page.
    static let space = RemoteKey(id: "space", label: "Space", glyph: .symbol("space"), press: .keyCode(49), inputLabels: ["Space", "Spacebar", "Play", "Pause"])
    static let escape = RemoteKey(id: "escape", label: "Escape", glyph: .symbol("escape"), press: .keyCode(53), inputLabels: ["Escape", "Esc"])
    static let `return` = RemoteKey(id: "return", label: "Return", glyph: .symbol("return"), press: .keyCode(36), inputLabels: ["Return", "Enter"])
    static let tab = RemoteKey(id: "tab", label: "Tab", glyph: .symbol("arrow.right.to.line"), press: .keyCode(48))
    static let delete = RemoteKey(id: "delete", label: "Delete", glyph: .symbol("delete.left"), press: .keyCode(51), inputLabels: ["Delete", "Backspace"])

    /// Lowercase press so the synthesized event carries no shift; uppercase
    /// cap because that's what a keyboard shows.
    private static func letter(_ character: Character) -> RemoteKey {
        let lower = String(character)
        let upper = lower.uppercased()
        return RemoteKey(id: lower, label: upper, glyph: .character(upper), press: .character(lower))
    }

    static let letters: [RemoteKey] = "abcdefghijklmnopqrstuvwxyz".map(letter)

    static let numbers: [RemoteKey] = "1234567890".map { digit in
        let cap = String(digit)
        return RemoteKey(id: cap, label: cap, glyph: .character(cap), press: .character(cap))
    }

    /// The unshifted punctuation caps, keyboard order; labels are the spoken
    /// names since the caps don't read aloud.
    static let symbols: [RemoteKey] = [
        ("`", "Grave"), ("-", "Minus"), ("=", "Equals"),
        ("[", "Left bracket"), ("]", "Right bracket"), ("\\", "Backslash"),
        (";", "Semicolon"), ("'", "Quote"),
        (",", "Comma"), (".", "Period"), ("/", "Slash"),
    ].map { cap, name in
        RemoteKey(id: cap, label: name, glyph: .character(cap), press: .character(cap))
    }

    static let functionKeys: [RemoteKey] = [
        (1, 122), (2, 120), (3, 99), (4, 118), (5, 96), (6, 97),
        (7, 98), (8, 100), (9, 101), (10, 109), (11, 103), (12, 111),
    ].map { number, code in
        RemoteKey(id: "f\(number)", label: "F\(number)", glyph: .character("F\(number)"), press: .keyCode(code))
    }

    struct Section: Identifiable {
        let title: String
        let keys: [RemoteKey]
        var id: String { title }
    }

    /// The key picker's contents, in display order.
    static let sections: [Section] = [
        Section(title: "Special", keys: [.up, .down, .left, .right, .space, .return, .escape, .tab, .delete]),
        Section(title: "Letters", keys: letters),
        Section(title: "Numbers", keys: numbers),
        Section(title: "Symbols", keys: symbols),
        Section(title: "Function Keys", keys: functionKeys),
    ]

    static let all: [RemoteKey] = sections.flatMap(\.keys)

    /// Catalog lookup for decoding a stored layout; nil for ids this version
    /// doesn't know (a key from a newer one). Stored ids are permanent: a renamed
    /// key's old id joins `idAliases` rather than being dropped, since a missing
    /// id silently empties every cell that used it.
    static func withID(_ id: String) -> RemoteKey? {
        let resolved = idAliases[id] ?? id
        return all.first { $0.id == resolved }
    }

    /// Old id → current id, for keys renamed after data holding them shipped.
    private static let idAliases: [String: String] = [:]

    /// The key's text form for chord caps, where SF Symbols can't compose
    /// ("⌘Z" needs a Z; "⇧↑" needs an arrow). Character keys are their own
    /// cap; the named keys use the standard keyboard glyphs.
    var chordCap: String {
        switch glyph {
        case .character(let cap):
            return cap
        case .symbol:
            return Self.symbolChordCaps[id] ?? label
        }
    }

    private static let symbolChordCaps: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "space": "␣", "escape": "⎋", "return": "↩", "tab": "⇥", "delete": "⌫",
    ]
}
