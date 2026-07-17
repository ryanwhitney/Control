import Foundation
import Testing
@testable import Control

/// The pad layout's stored shape and the key catalog's integrity. The layout
/// is user data that outlives app versions, so the contract under test is
/// tolerance: an entry a given version can't read must cost that one cell,
/// never the whole layout.
struct KeyPadLayoutTests {
    @Test func standardLayoutMatchesTheOriginalPad() {
        let layout = KeyPadLayout.standard
        #expect(layout.cells.count == KeyPadLayout.cellCount)
        #expect(layout[row: 0, column: 0] == .key(.escape))
        #expect(layout[row: 0, column: 2] == .key(.return))
        #expect(layout[row: 1, column: 1] == .key(.up))
        #expect(layout[row: 2, column: 0] == .key(.left))
        #expect(layout[row: 2, column: 1] == .key(.space))
        #expect(layout[row: 2, column: 2] == .key(.right))
        #expect(layout[row: 3, column: 1] == .key(.down))
        #expect(layout.cells.compactMap { $0 }.count == 7)
    }

    @Test func layoutSurvivesACodableRoundTrip() throws {
        var layout = KeyPadLayout.standard
        layout[row: 0, column: 1] = .key(RemoteKey.withID("m")!)
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(KeyPadLayout.self, from: data)
        #expect(decoded == layout)
    }

    /// A stored cell this version can't read — a key id or a command type from
    /// a newer version (a future shortcut, say) — must decode as an empty cell,
    /// not fail the whole layout back to standard. A short array must pad out
    /// to the fixed cell count so grid indexing can't trap.
    @Test func unreadableCellsDecodeAsEmptyAndShortLayoutsPadOut() throws {
        let json = """
        {"cells": [
            {"type": "key", "key": "up"},
            {"type": "key", "key": "hyperspace"},
            {"type": "shortcut", "name": "Undo"},
            null
        ]}
        """
        let layout = try JSONDecoder().decode(KeyPadLayout.self, from: Data(json.utf8))
        #expect(layout.cells[0] == .key(.up))
        #expect(layout.cells[1] == nil)
        #expect(layout.cells[2] == nil)
        #expect(layout.cells.count == KeyPadLayout.cellCount)
    }

    @Test func catalogIDsAreUnique() {
        let ids = RemoteKey.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: Script generation

    @Test func namedKeysSendPositionalKeyCodes() {
        let script = KeyboardApp().executeAction(.key(.up))
        #expect(script.contains("key code 126"))
    }

    @Test func characterKeysSendLayoutIndependentKeystrokes() {
        let script = KeyboardApp().executeAction(.key(RemoteKey.withID("a")!))
        #expect(script.contains("keystroke \"a\""))
    }

    @Test func backslashIsEscapedForAppleScript() {
        let script = KeyboardApp().executeAction(.key(RemoteKey.withID("\\")!))
        #expect(script.contains(#"keystroke "\\""#))
    }
}
