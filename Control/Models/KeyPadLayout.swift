import Foundation

/// What one pad cell sends. Views render through the computed properties below
/// rather than unwrapping cases, so a new command kind lands here plus
/// `AppAction`, not across the view layer.
enum PadCommand: Equatable {
    case key(RemoteKey)
    case shortcut(KeyShortcut)

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

    /// Under the cap in the editor and picker. nil for character keys, which
    /// are their own label; an arrow glyph alone isn't.
    var caption: String? {
        switch self {
        case .key(let key):
            if case .symbol = key.glyph { return key.label }
            return nil
        case .shortcut(let shortcut):
            return shortcut.captionText
        }
    }

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

/// One zone of the pad: a column count plus row-major cells, always padded to
/// whole rows so grid indexing can't trap. Rendered at its *stored* dimensions,
/// so a version that widens a zone doesn't strand older data.
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

    /// Coordinate-true: (row, column) keeps its meaning. A flat reflow would
    /// scramble — index 3 of a 3-wide grid is elsewhere in a 4-wide one.
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

    /// An entry this version can't read becomes an empty cell, rather than
    /// failing the whole layout back to `standard`.
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

/// `allCases` order is layout order, top to bottom.
enum PadZone: String, CaseIterable {
    case utility, pad
}

struct CellAddress: Hashable, Identifiable {
    let zone: PadZone
    let index: Int

    var id: String { "\(zone.rawValue)-\(index)" }
}

/// The user's arrangement, in two zones: the utility strip, and the pad proper
/// whose D-pad shape survives reflows intact while the strip moves around it.
struct KeyPadLayout: Equatable {
    /// Bump only together with a migration step in the decoder.
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

    /// One of every cap shape, for previews to iterate styling against.
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
        // Read so a future decoder can branch on it; v1 has nothing to migrate.
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

/// An unreadable entry costs only itself, not the whole library.
private struct LossyShortcut: Decodable {
    let shortcut: KeyShortcut?

    init(from decoder: Decoder) {
        shortcut = try? KeyShortcut(from: decoder)
    }
}

/// Persists the layout and publishes edits. The pad and its editor share one
/// instance, so an edit shows on the pad behind the sheet as it's made.
@MainActor
final class KeyPadLayoutStore: ObservableObject {
    static let shared = KeyPadLayoutStore()

    private static let defaultsKey = "KeyPadLayout"
    private static let shortcutsKey = "KeyPadCustomShortcuts"
    private static let hiddenPresetsKey = "KeyPadHiddenPresetShortcuts"

    /// False for preview stores, which must never overwrite the saved pad.
    private let persists: Bool

    @Published var layout: KeyPadLayout {
        didSet {
            guard persists else { return }
            // Clearing rather than storing a copy keeps users on the default
            // tracking it, so they reach a future version's standard layout.
            if layout == .standard {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            } else if let data = try? JSONEncoder().encode(layout) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Cells hold their own copy, so deleting one here never breaks a placed cap.
    @Published var customShortcuts: [KeyShortcut] {
        didSet {
            guard persists, let data = try? JSONEncoder().encode(customShortcuts) else { return }
            UserDefaults.standard.set(data, forKey: Self.shortcutsKey)
        }
    }

    /// The presets are a fixed catalog, so "deleting" one is hiding it here;
    /// rebuilding the same chord brings it back.
    @Published var hiddenPresetIDs: Set<String> {
        didSet {
            guard persists else { return }
            UserDefaults.standard.set(Array(hiddenPresetIDs), forKey: Self.hiddenPresetsKey)
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
           let saved = try? JSONDecoder().decode([LossyShortcut].self, from: data) {
            customShortcuts = saved.compactMap(\.shortcut)
        } else {
            customShortcuts = []
        }
        hiddenPresetIDs = Set(UserDefaults.standard.array(forKey: Self.hiddenPresetsKey) as? [String] ?? [])
    }

    private init(previewLayout: KeyPadLayout) {
        persists = false
        layout = previewLayout
        customShortcuts = []
        hiddenPresetIDs = []
    }

    /// De-duplicated by content, so the row can key on `contentID` even if a
    /// future preset ships a chord a user already saved.
    var availableShortcuts: [KeyShortcut] {
        var seen = Set<String>()
        let visiblePresets = KeyShortcut.presets.filter { !hiddenPresetIDs.contains($0.contentID) }
        return (visiblePresets + customShortcuts).filter { seen.insert($0.contentID).inserted }
    }

    /// A chord matching a preset un-hides that preset rather than duplicating it.
    func rememberShortcut(_ shortcut: KeyShortcut) {
        if KeyShortcut.presets.contains(where: { $0.contentID == shortcut.contentID }) {
            hiddenPresetIDs.remove(shortcut.contentID)
            return
        }
        guard !customShortcuts.contains(where: { $0.contentID == shortcut.contentID }) else { return }
        customShortcuts.append(shortcut)
    }

    /// A preset is hidden, a creation dropped. Cells keep their own copy either
    /// way, so a placed cap is never broken.
    func deleteShortcut(_ shortcut: KeyShortcut) {
        if KeyShortcut.presets.contains(where: { $0.contentID == shortcut.contentID }) {
            hiddenPresetIDs.insert(shortcut.contentID)
        } else {
            customShortcuts.removeAll { $0.contentID == shortcut.contentID }
        }
    }

    /// A throwaway store, so previews never touch the persisted layout.
    static func preview(_ layout: KeyPadLayout = .standard) -> KeyPadLayoutStore {
        KeyPadLayoutStore(previewLayout: layout)
    }

    func reset() {
        layout = .standard
    }
}
