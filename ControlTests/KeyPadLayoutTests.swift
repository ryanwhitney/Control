import Foundation
import Testing
@testable import Control

/// The layout is user data that outlives app versions, so two contracts matter:
/// tolerance (an unreadable entry costs that cell, never the whole layout) and
/// wire-format stability (a refactor must fail here, not in the field).
struct KeyPadLayoutTests {
    @Test func standardLayoutMatchesTheOriginalPad() {
        let layout = KeyPadLayout.standard
        #expect(layout.utility.columns == 3)
        #expect(layout.utility.cells == [.key(.escape), nil, .key(.return)])
        #expect(layout.pad.columns == 3)
        #expect(layout.pad.cells.count == 9)
        #expect(layout.pad[0, 1] == .key(.up))
        #expect(layout.pad[1, 0] == .key(.left))
        #expect(layout.pad[1, 1] == .key(.space))
        #expect(layout.pad[1, 2] == .key(.right))
        #expect(layout.pad[2, 1] == .key(.down))
        #expect(layout.pad.cells.compactMap { $0 }.count == 5)
    }

    @Test func layoutSurvivesACodableRoundTrip() throws {
        var layout = KeyPadLayout.standard
        layout[CellAddress(zone: .utility, index: 1)] = .key(RemoteKey.withID("m")!)
        layout[CellAddress(zone: .pad, index: 0)] = .shortcut(KeyShortcut.presets[0])
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(KeyPadLayout.self, from: data)
        #expect(decoded == layout)
    }

    /// The exact v1 wire format. Failing here means the stored shape changed,
    /// which needs a version bump and a migration.
    @Test func goldenV1FixtureDecodes() throws {
        let fixture = """
        {"version": 1,
         "utility": {"columns": 3, "cells": [{"type": "key", "key": "escape"}, null, {"type": "key", "key": "return"}]},
         "pad": {"columns": 3, "cells": [
            null, {"type": "key", "key": "up"}, null,
            {"type": "key", "key": "left"},
            {"type": "shortcut", "presses": [{"key": "z", "modifiers": ["command"]}]},
            {"type": "key", "key": "right"},
            null, {"type": "key", "key": "down"}, null]}}
        """
        let layout = try JSONDecoder().decode(KeyPadLayout.self, from: Data(fixture.utf8))
        var expected = KeyPadLayout.standard
        expected[CellAddress(zone: .pad, index: 4)] = .shortcut(
            KeyShortcut(name: nil, presses: [KeyPress(key: RemoteKey.withID("z")!, modifiers: [.command])])
        )
        #expect(layout == expected)
    }

    /// The pre-release flat shape has no zones, so it must fail decode rather
    /// than half-parse. Nothing shipped in that shape, only test builds.
    @Test func preReleaseFlatBlobsFailDecodeCleanly() {
        let legacy = #"{"cells": [{"type": "key", "key": "up"}]}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(KeyPadLayout.self, from: Data(legacy.utf8))
        }
    }

    /// An unreadable cell decodes as empty rather than failing the layout, and
    /// short rows pad out so grid indexing can't trap.
    @Test func unreadableCellsDecodeAsEmptyNotAsFailure() throws {
        let json = """
        {"version": 1,
         "utility": {"columns": 3, "cells": [{"type": "key", "key": "up"}, {"type": "key", "key": "hyperspace"}]},
         "pad": {"columns": 3, "cells": [
            {"type": "chord-sequence", "name": "Future"},
            {"type": "shortcut", "presses": [{"key": "z", "modifiers": ["hyper"]}]},
            {"type": "shortcut", "presses": []},
            null]}}
        """
        let layout = try JSONDecoder().decode(KeyPadLayout.self, from: Data(json.utf8))
        #expect(layout.utility.cells == [.key(.up), nil, nil])
        #expect(layout.pad.cells.count == 6)
        #expect(layout.pad.cells.allSatisfy { $0 == nil })
    }

    @Test func reflowKeepsCoordinatesNotIndices() {
        let grid = CellGrid(columns: 3, cells: [
            .key(.up), nil, .key(.down),
            .key(.left), .key(.space), .key(.right),
        ])
        let wider = grid.reflowed(toColumns: 4)
        #expect(wider.columns == 4)
        #expect(wider[0, 0] == .key(.up))
        #expect(wider[0, 2] == .key(.down))
        #expect(wider[0, 3] == nil)
        #expect(wider[1, 1] == .key(.space))
        let narrower = grid.reflowed(toColumns: 2)
        #expect(narrower[0, 0] == .key(.up))
        #expect(narrower[1, 1] == .key(.space))
        // The third column drops; nothing shifts into its place.
        #expect(narrower.cells.count == 4)
    }

    @Test func partialRowsPadOutToWholeRows() {
        let grid = CellGrid(columns: 3, cells: [.key(.up), .key(.down), .key(.left), .key(.right)])
        #expect(grid.cells.count == 6)
        #expect(grid.rowCount == 2)
        #expect(grid[1, 0] == .key(.right))
    }

    // MARK: Icons

    /// Flat on the wire: an icon is one extra field beside the command's own,
    /// so v1 data needs no migration and older versions read the bare command.
    @Test func iconsAreAnAdditiveFieldOnTheCell() throws {
        let cell = PadCell(command: .key(.space), icon: "playpause.fill")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cell)) as? [String: String]
        #expect(object == ["type": "key", "key": "space", "icon": "playpause.fill"])
        let bare = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PadCell.key(.space))) as? [String: String]
        #expect(bare == ["type": "key", "key": "space"])
    }

    @Test func iconedLayoutSurvivesACodableRoundTrip() throws {
        var layout = KeyPadLayout.standard
        layout[CellAddress(zone: .pad, index: 4)]?.icon = "playpause.fill"
        layout[CellAddress(zone: .utility, index: 1)] = PadCell(command: .shortcut(KeyShortcut.presets[0]), icon: "arrow.uturn.backward")
        let decoded = try JSONDecoder().decode(KeyPadLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }

    /// A symbol this iOS lacks (stored by a newer version) falls back to the
    /// key's own cap rather than drawing nothing.
    @Test func undrawableIconsFallBackToTheKeysCap() {
        let cell = PadCell(command: .key(.space), icon: "not.a.real.symbol")
        #expect(cell.glyph == RemoteKey.space.glyph)
        #expect(cell.keyHint == nil)
        #expect(cell.label == "Space")
    }

    /// The key stays visible under an icon: the cap for characters, the name
    /// for symbol keys, the chord for shortcuts.
    @Test func iconedCellsHintTheKeyTheySend() {
        #expect(PadCell(command: .key(.space), icon: "play.fill").keyHint == "Space")
        #expect(PadCell(command: .key(RemoteKey.withID("`")!), icon: "star.fill").keyHint == "`")
        #expect(PadCell(command: .shortcut(KeyShortcut.presets[0]), icon: "arrow.uturn.backward").keyHint == "⌘Z")
        #expect(PadCell.key(.space).keyHint == nil)
    }

    @Test func iconedCellsSpeakTheIconThenTheKey() {
        let cell = PadCell(command: .key(.space), icon: "play.fill")
        #expect(cell.label == "Play, Space")
        #expect(cell.inputLabels.contains("Play"))
        #expect(cell.inputLabels.contains("Spacebar"))
    }

    @Test func everyCatalogIconExistsAndIsUnique() {
        let ids = PadIcon.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(PadIcon.isDrawable(id), "\(id) isn't an SF Symbol on this iOS")
        }
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

    // MARK: Shortcuts

    @Test func chordsSendTheirModifiersInAUsingClause() {
        let redo = KeyShortcut(name: nil, presses: [
            KeyPress(key: RemoteKey.withID("z")!, modifiers: [.shift, .command]),
        ])
        let script = KeyboardApp().executeAction(.shortcut(redo))
        #expect(script.contains(#"keystroke "z" using {shift down, command down}"#))
    }

    @Test func keyCodeChordsCarryModifiersToo() {
        let shortcut = KeyShortcut(name: nil, presses: [
            KeyPress(key: .up, modifiers: [.command]),
        ])
        let script = KeyboardApp().executeAction(.shortcut(shortcut))
        #expect(script.contains("key code 126 using {command down}"))
    }

    /// Canonical ⌃⌥⇧⌘ order however they were supplied, so the cap, caption and
    /// script don't vary with input order.
    @Test func modifiersNormalizeToCanonicalOrder() {
        let press = KeyPress(key: RemoteKey.withID("f")!, modifiers: [.command, .control])
        #expect(press.modifiers == [.control, .command])
        #expect(press.capText == "⌃⌘F")
        #expect(press.captionText == "Ctrl + Cmd + F")
    }

    @Test func presetsAreDistinctAndSpellThemselves() {
        let ids = KeyShortcut.presets.map(\.contentID)
        #expect(Set(ids).count == ids.count)
        let undo = KeyShortcut.presets[0]
        #expect(undo.capText == "⌘Z")
        #expect(undo.captionText == "Cmd + Z")
        // The chord, never the preset's name: nothing on screen shows the name.
        #expect(undo.spokenText == "Command Z")
    }
}
