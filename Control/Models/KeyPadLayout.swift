import Foundation

/// What one pad cell sends. A one-case enum on purpose: the planned custom
/// shortcut (a named sequence of modified presses, e.g. ⌘Z) becomes one more
/// case here plus its computed properties — additive for stored layouts and
/// for the views, which render commands through these properties rather than
/// unwrapping keys themselves — not a migration off a bare-key format.
enum PadCommand: Equatable {
    case key(RemoteKey)

    /// The runtime action a press of this cell fires.
    var action: AppAction {
        switch self {
        case .key(let key): return .key(key)
        }
    }

    var label: String {
        switch self {
        case .key(let key): return key.label
        }
    }

    var glyph: RemoteKey.Glyph {
        switch self {
        case .key(let key): return key.glyph
        }
    }

    /// Alternative spoken names for Voice Control.
    var inputLabels: [String] {
        switch self {
        case .key(let key): return key.inputLabels
        }
    }
}

extension PadCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key
    }

    private enum Kind: String, Codable {
        case key
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
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let key):
            try container.encode(Kind.key, forKey: .type)
            try container.encode(key.id, forKey: .key)
        }
    }
}

/// The user's arrangement of the generic key pad: a fixed 3×4 grid of cells,
/// row-major, nil is an empty space. The pad and its editor both render this
/// one model, so empty cells hold their place identically in each.
struct KeyPadLayout: Equatable {
    static let columnCount = 3
    static let rowCount = 4
    static let cellCount = columnCount * rowCount

    /// Always exactly `cellCount` entries — decoding normalizes the length so
    /// grid indexing can't trap on stored data.
    var cells: [PadCommand?]

    /// The original hardcoded pad: escape/return at the top corners, D-pad
    /// with space at its centre.
    static let standard = KeyPadLayout(cells: [
        .key(.escape), nil,          .key(.return),
        nil,           .key(.up),    nil,
        .key(.left),   .key(.space), .key(.right),
        nil,           .key(.down),  nil,
    ])

    /// One of every cap shape — letters, digits, punctuation, F-keys, arrows,
    /// captioned symbols — for previews to iterate styling against. The
    /// standard layout has no character caps, so styling passes need this one.
    /// (Force-unwraps are safe: the ids are catalog constants under test.)
    static let glyphSampler = KeyPadLayout(cells: [
        .key(RemoteKey.withID("a")!), .key(RemoteKey.withID("f12")!), .key(RemoteKey.withID("`")!),
        .key(RemoteKey.withID("m")!), .key(.up),                      .key(RemoteKey.withID("7")!),
        .key(.left),                  .key(.space),                   .key(.right),
        .key(.escape),                .key(.down),                    .key(RemoteKey.withID("\\")!),
    ])

    static func index(row: Int, column: Int) -> Int {
        row * columnCount + column
    }

    subscript(row row: Int, column column: Int) -> PadCommand? {
        get { cells[Self.index(row: row, column: column)] }
        set { cells[Self.index(row: row, column: column)] = newValue }
    }
}

extension KeyPadLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case cells
    }

    /// Decodes each cell inside its own never-failing wrapper: one entry this
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
        var cells = try container.decode([LossyCell].self, forKey: .cells).map(\.command)
        if cells.count > Self.cellCount {
            cells.removeLast(cells.count - Self.cellCount)
        }
        while cells.count < Self.cellCount {
            cells.append(nil)
        }
        self.cells = cells
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cells.map(LossyCell.init), forKey: .cells)
    }
}

/// Persists the pad layout and publishes edits. The pad and its editor share
/// this one instance, so an edit shows on the pad behind the sheet as it's
/// made.
@MainActor
final class KeyPadLayoutStore: ObservableObject {
    static let shared = KeyPadLayoutStore()

    private static let defaultsKey = "KeyPadLayout"

    /// False only for preview stores: interacting with a preview must never
    /// overwrite the saved pad.
    private let persists: Bool

    @Published var layout: KeyPadLayout {
        didSet {
            guard persists, let data = try? JSONEncoder().encode(layout) else { return }
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
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
    }

    private init(previewLayout: KeyPadLayout) {
        persists = false
        layout = previewLayout
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
