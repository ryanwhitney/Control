import Foundation

/// What one pad cell sends: a single key, or a shortcut (modified presses,
/// e.g. ⌘Z). Views render commands through the computed properties below
/// rather than unwrapping cases, so a new command kind lands here plus
/// `AppAction`, not across the view layer.
enum PadCommand: Equatable {
    case key(RemoteKey)
    case shortcut(KeyShortcut)

    /// The runtime action a press of this cell fires.
    var action: AppAction {
        switch self {
        case .key(let key): return .key(key)
        case .shortcut(let shortcut): return .shortcut(shortcut)
        }
    }

    var label: String {
        switch self {
        case .key(let key): return key.label
        case .shortcut(let shortcut): return shortcut.spokenText
        }
    }

    var glyph: RemoteKey.Glyph {
        switch self {
        case .key(let key): return key.glyph
        case .shortcut(let shortcut): return .character(shortcut.capText)
        }
    }

    /// The caption under the cap in the editor and picker: symbol-glyph keys
    /// name themselves ("Escape" — an arrow glyph alone doesn't), character
    /// keys don't ("A" is its own label), and shortcuts spell their chord
    /// ("Cmd + Z").
    var caption: String? {
        switch self {
        case .key(let key):
            if case .symbol = key.glyph { return key.label }
            return nil
        case .shortcut(let shortcut):
            return shortcut.captionText
        }
    }

    /// Alternative spoken names for Voice Control.
    var inputLabels: [String] {
        switch self {
        case .key(let key): return key.inputLabels
        case .shortcut(let shortcut): return [shortcut.spokenText]
        }
    }
}

extension PadCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key, name, presses
    }

    private enum Kind: String, Codable {
        case key, shortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .key:
            let id = try container.decode(String.self, forKey: .key)
            guard let key = RemoteKey.withID(id) else {
                throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "Unknown key id \(id)")
            }
            self = .key(key)
        case .shortcut:
            let presses = try container.decode([KeyPress].self, forKey: .presses)
            guard !presses.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .presses, in: container, debugDescription: "Shortcut with no presses")
            }
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            self = .shortcut(KeyShortcut(name: name, presses: presses))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let key):
            try container.encode(Kind.key, forKey: .type)
            try container.encode(key.id, forKey: .key)
        case .shortcut(let shortcut):
            try container.encode(Kind.shortcut, forKey: .type)
            try container.encodeIfPresent(shortcut.name, forKey: .name)
            try container.encode(shortcut.presses, forKey: .presses)
        }
    }
}

/// One rectangular zone of the pad: a column count plus row-major cells,
/// always padded to whole rows so grid indexing can't trap. Zones render
/// from their *stored* dimensions, so a future version that widens a zone
/// doesn't strand older data — and `reflowed(toColumns:)` migrates by
/// coordinate when a shape change does ship (flat reflow would scramble:
/// index 3 of a 3-wide grid is a different place in a 4-wide one).
struct CellGrid: Equatable {
    var columns: Int
    var cells: [PadCommand?]

    init(columns: Int, cells: [PadCommand?]) {
        self.columns = max(1, columns)
        self.cells = Self.paddedToWholeRows(cells, columns: self.columns)
    }

    var rowCount: Int { cells.count / columns }

    subscript(row: Int, column: Int) -> PadCommand? {
        get { cells[row * columns + column] }
        set { cells[row * columns + column] = newValue }
    }

    /// Coordinate-true reshape: (row, column) keeps its meaning, columns
    /// beyond the new width drop, new columns arrive empty.
    func reflowed(toColumns newColumns: Int) -> CellGrid {
        let newColumns = max(1, newColumns)
        guard newColumns != columns else { return self }
        var reflowed: [PadCommand?] = []
        for row in 0..<rowCount {
            for column in 0..<newColumns {
                reflowed.append(column < columns ? self[row, column] : nil)
            }
        }
        return CellGrid(columns: newColumns, cells: reflowed)
    }

    private static func paddedToWholeRows(_ cells: [PadCommand?], columns: Int) -> [PadCommand?] {
        var cells = cells
        if cells.isEmpty {
            return Array(repeating: nil, count: columns)
        }
        let remainder = cells.count % columns
        if remainder != 0 {
            cells.append(contentsOf: Array(repeating: nil, count: columns - remainder))
        }
        return cells
    }
}

extension CellGrid: Codable {
    private enum CodingKeys: String, CodingKey {
        case columns, cells
    }

    /// Decodes each cell inside its own never-failing wrapper: an entry this
    /// version can't read (a key id or command type from a newer version)
    /// becomes an empty cell instead of failing the whole layout back to
    /// `standard`.
    private struct LossyCell: Codable {
        let command: PadCommand?

        init(_ command: PadCommand?) {
            self.command = command
        }

        init(from decoder: Decoder) {
            command = try? PadCommand(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            if let command {
                try command.encode(to: encoder)
            } else {
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try container.decode(Int.self, forKey: .columns)
        guard columns > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .columns, in: container, debugDescription: "Non-positive column count")
        }
        let cells = try container.decode([LossyCell].self, forKey: .cells).map(\.command)
        self.init(columns: columns, cells: cells)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(columns, forKey: .columns)
        try container.encode(cells.map(LossyCell.init), forKey: .cells)
    }
}

/// Which zone of the pad a cell lives in; `allCases` order is layout order,
/// top to bottom. A future bottom strip is one more case plus an optional
/// stored field — additive, like everything in this file.
enum PadZone: String, CaseIterable {
    case utility, pad
}

/// A cell's coordinates: zone plus row-major index within it.
struct CellAddress: Hashable, Identifiable {
    let zone: PadZone
    let index: Int

    var id: String { "\(zone.rawValue)-\(index)" }
}

/// The user's arrangement of the generic key pad, in two zones: the utility
/// strip (escape/return — a plain row) and the pad proper, whose 3×3 D-pad
/// shape is the page's point — it survives reflows intact while the strip
/// moves around it (beside it in landscape). Empty cells hold their places,
/// so the pad and its editor always agree on positions.
struct KeyPadLayout: Equatable {
    /// The wire-format generation. Bump only together with a migration step
    /// in the decoder. Pre-versioning test blobs (the flat 12-cell shape)
    /// deliberately fail decode and start fresh from `standard` — nothing
    /// shipped in that shape.
    static let currentVersion = 1

    var utility: CellGrid
    var pad: CellGrid

    static let standard = KeyPadLayout(
        utility: CellGrid(columns: 3, cells: [.key(.escape), nil, .key(.return)]),
        pad: CellGrid(columns: 3, cells: [
            nil,         .key(.up),    nil,
            .key(.left), .key(.space), .key(.right),
            nil,         .key(.down),  nil,
        ])
    )

    /// One of every cap shape — letters, digits, punctuation, F-keys, arrows,
    /// captioned symbols, chords — for previews to iterate styling against.
    /// (Force-unwraps are safe: the ids are catalog constants under test.)
    static let glyphSampler = KeyPadLayout(
        utility: CellGrid(columns: 3, cells: [
            .key(.escape), .shortcut(KeyShortcut.presets[0]), .key(.delete),
        ]),
        pad: CellGrid(columns: 3, cells: [
            .key(RemoteKey.withID("a")!),      .key(RemoteKey.withID("f12")!), .key(RemoteKey.withID("`")!),
            .key(.left),                       .key(.space),                   .key(.right),
            .shortcut(KeyShortcut.presets[4]), .key(.down),                    .key(RemoteKey.withID("7")!),
        ])
    )

    subscript(zone: PadZone) -> CellGrid {
        get {
            switch zone {
            case .utility: return utility
            case .pad: return pad
            }
        }
        set {
            switch zone {
            case .utility: utility = newValue
            case .pad: pad = newValue
            }
        }
    }

    subscript(address: CellAddress) -> PadCommand? {
        get { self[address.zone].cells[address.index] }
        set { self[address.zone].cells[address.index] = newValue }
    }

    mutating func swapCommands(_ a: CellAddress, _ b: CellAddress) {
        let held = self[a]
        self[a] = self[b]
        self[b] = held
    }
}

extension KeyPadLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, utility, pad
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // v1 has no older siblings to migrate; the version is read so a
        // future v2 decoder can branch on it, and written so v1 data is
        // identifiable forever.
        _ = try container.decodeIfPresent(Int.self, forKey: .version)
        utility = try container.decode(CellGrid.self, forKey: .utility)
        pad = try container.decode(CellGrid.self, forKey: .pad)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(utility, forKey: .utility)
        try container.encode(pad, forKey: .pad)
    }
}

/// Persists the pad layout and publishes edits. The pad and its editor share
/// this one instance, so an edit shows on the pad behind the sheet as it's
/// made.
@MainActor
final class KeyPadLayoutStore: ObservableObject {
    static let shared = KeyPadLayoutStore()

    private static let defaultsKey = "KeyPadLayout"
    private static let shortcutsKey = "KeyPadCustomShortcuts"

    /// False only for preview stores: interacting with a preview must never
    /// overwrite the saved pad.
    private let persists: Bool

    @Published var layout: KeyPadLayout {
        didSet {
            guard persists else { return }
            // Landing exactly on `standard` — Restore, or editing back by
            // hand — clears the entry rather than freezing a copy of it:
            // users on the default keep *tracking* the default, so a future
            // version's improved standard layout reaches them.
            if layout == .standard {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            } else if let data = try? JSONEncoder().encode(layout) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Shortcuts the user has built, shown in the picker's Shortcuts row
    /// after the presets. Cells hold their own copy of a shortcut, so
    /// deleting one here never breaks a placed cap.
    @Published var customShortcuts: [KeyShortcut] {
        didSet {
            guard persists, let data = try? JSONEncoder().encode(customShortcuts) else { return }
            UserDefaults.standard.set(data, forKey: Self.shortcutsKey)
        }
    }

    private init() {
        persists = true
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(KeyPadLayout.self, from: data) {
            layout = saved
        } else {
            layout = .standard
        }
        if let data = UserDefaults.standard.data(forKey: Self.shortcutsKey),
           let saved = try? JSONDecoder().decode([KeyShortcut].self, from: data) {
            customShortcuts = saved
        } else {
            customShortcuts = []
        }
    }

    private init(previewLayout: KeyPadLayout) {
        persists = false
        layout = previewLayout
        customShortcuts = []
    }

    /// Adds to the library unless an identical chord is already offered (as a
    /// preset or earlier creation) — the assignment itself still happens
    /// either way.
    func rememberShortcut(_ shortcut: KeyShortcut) {
        let known = (KeyShortcut.presets + customShortcuts).map(\.contentID)
        guard !known.contains(shortcut.contentID) else { return }
        customShortcuts.append(shortcut)
    }

    func removeCustomShortcut(_ shortcut: KeyShortcut) {
        customShortcuts.removeAll { $0.contentID == shortcut.contentID }
    }

    /// A throwaway store so previews can render (and interact with) any
    /// layout without touching the persisted one.
    static func preview(_ layout: KeyPadLayout = .standard) -> KeyPadLayoutStore {
        KeyPadLayoutStore(previewLayout: layout)
    }

    func reset() {
        layout = .standard
    }
}
