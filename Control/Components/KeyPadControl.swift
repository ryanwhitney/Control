import SwiftUI

/// The generic key pad, rendered from the user's `KeyPadLayout` zones: the
/// utility strip and the pad proper, whose filled cells send their key to
/// whatever app is frontmost on the Mac (see `KeyboardApp`) and whose empty
/// cells hold their place, so the shapes always match the editor's.
struct KeyPadControl: View {
    let platform: any AppPlatform
    /// Phone landscape: the utility strip pivots to a column beside the pad
    /// — three rows tall instead of four — while the pad keeps its
    /// directionally-meaningful shape untouched.
    let isCompact: Bool
    @EnvironmentObject var controller: AppController
    /// Injectable so previews can render arbitrary layouts; defaults to the
    /// persisted store.
    @ObservedObject var layoutStore: KeyPadLayoutStore = .shared

    private var spacing: CGFloat { isCompact ? 6 : 8 }
    /// Breathing room between the zones, so they read as grouped without a
    /// divider.
    private let zoneGap: CGFloat = 14

    var body: some View {
        if isCompact {
            // Landscape fills whatever the page grants and sizes the caps
            // from it — as big a pad as the space allows, not a fixed 44pt.
            GeometryReader { proxy in
                let capSize = compactCapSize(in: proxy.size)
                HStack(spacing: zoneGap + 4) {
                    utilityColumn(capSize: capSize)
                    zoneGrid(layoutStore.layout.pad, capSize: capSize)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            // Portrait keeps the pad at its natural height so the pager's
            // spacers centre it in the page (a fill-the-space pass collapsed
            // those spacers and left it sitting low). Caps are just bigger than
            // the old 60pt — Apple-keypad-ish, and small-phone safe at four rows.
            VStack(spacing: zoneGap) {
                zoneGrid(layoutStore.layout.utility, capSize: portraitCapSize)
                zoneGrid(layoutStore.layout.pad, capSize: portraitCapSize)
            }
        }
    }

    /// Fixed rather than space-filling: portrait relies on the pager's spacers
    /// to centre a natural-height pad, so the pad must report a real height. 84
    /// is a comfortable bump from 60 that still clears the volume row on the
    /// smallest phones' four-row layout.
    private var portraitCapSize: CGFloat { 84 }

    /// The largest cap the granted space can hold: height against the taller
    /// zone's rows, width against strip + gap + pad columns, floored at the
    /// 44pt tap-target minimum and capped before comedy sizes.
    private func compactCapSize(in available: CGSize) -> CGFloat {
        let pad = layoutStore.layout.pad
        let utilityCount = layoutStore.layout.utility.cells.count
        let rows = CGFloat(max(pad.rowCount, utilityCount, 1))
        let heightDriven = (available.height - (rows - 1) * spacing) / rows
        let columns = CGFloat(pad.columns)
        let widthDriven = (available.width - (zoneGap + 4) - (columns - 1) * spacing) / (columns + 1)
        return min(max(44, min(heightDriven, widthDriven)), 100)
    }

    /// A zone at its stored dimensions — the views never assume a shape, so
    /// stored data from a version with wider zones still renders.
    private func zoneGrid(_ grid: CellGrid, capSize: CGFloat) -> some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(0..<grid.rowCount, id: \.self) { row in
                GridRow {
                    ForEach(0..<grid.columns, id: \.self) { column in
                        cellView(grid[row, column], capSize: capSize)
                    }
                }
            }
        }
    }

    /// The utility strip pivoted for landscape: same cells, top-to-bottom.
    private func utilityColumn(capSize: CGFloat) -> some View {
        VStack(spacing: spacing) {
            ForEach(Array(layoutStore.layout.utility.cells.enumerated()), id: \.offset) { _, command in
                cellView(command, capSize: capSize)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ command: PadCommand?, capSize: CGFloat) -> some View {
        if let command {
            commandButton(command, capSize: capSize)
        } else {
            // Sized, not `gridCellUnsizedAxes`: a fully empty row or column
            // must keep its footprint so key positions stay where the editor
            // shows them.
            Color.clear.frame(width: capSize, height: capSize)
        }
    }

    private func commandButton(_ command: PadCommand, capSize: CGFloat) -> some View {
        // Font tracks the cap at the portrait ratio (36pt glyph in a 60pt cap).
        PadKeyButton(command: command, size: capSize, fontSize: capSize * 0.6) {
            // Two independent tasks on purpose. The key goes out as a bare
            // System Events statement so a run of presses drains at the speed of
            // the link rather than of a status read, and the readout refresh is
            // fired alongside it rather than chained behind it — nothing waits
            // for the key command to come back. `updateState`'s own 2 s dedupe
            // keeps a burst from queueing a refresh per press.
            Task {
                await controller.executeActionWithoutStatus(platform: platform, action: command.action)
            }
            Task {
                await controller.updateState(for: platform)
            }
        }
    }
}

/// One live pad key — the cap's full styling around IconButtonStyle. A
/// stand-alone view (no controller, no store) so the "Key caps" preview can
/// render every cap shape directly for styling passes.
struct PadKeyButton: View {
    let command: PadCommand
    var size: CGFloat = 60
    var fontSize: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Sized by IconButtonStyle's font rather than a resizable frame (the
            // transport row's approach): these glyphs don't share an aspect
            // ratio — the arrows are square, space/escape/return are wide and
            // short — so a uniform box would render space as a sliver. Font
            // sizing gives them Apple's optical balance instead.
            KeyCapGlyph(glyph: command.glyph, wrapsLongText: true)
                .accessibilityLabel(command.label)
        }
        .padding(4)
        .buttonStyle(IconButtonStyle(width: size, height: size, fontSize: fontSize))
        .accessibilityInputLabels(command.inputLabels)
    }
}

/// A cell's key cap, as the pad and the editor both draw it: SF Symbol keys
/// as their glyph, character keys as the character itself. Font size comes
/// from the enclosing style/view; multi-character caps ("F12") scale down
/// rather than clip their fixed frame.
struct KeyCapGlyph: View {
    let glyph: RemoteKey.Glyph
    /// The live pad wraps a long chord ("⌃⌥⇧⌘Z") onto a second line after the
    /// second glyph, so it reads at a legible size in the square cap rather than
    /// shrinking to a sliver on one line. The editor and picker keep one line —
    /// they caption the chord in full beneath the cap.
    var wrapsLongText = false

    var body: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
        case .character(let text):
            Text(wrapsLongText ? Self.wrapped(text) : text)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(wrapsLongText ? 2 : 1)
                .minimumScaleFactor(0.25)
        }
    }

    /// Splits a 4-or-more-glyph chord as evenly as possible across two lines,
    /// the shorter half first (4 → 2+2, 5 → 2+3, 7 → 3+4). Shorter caps
    /// ("A", "⌘V", "⌃⌘F") stay on one line. This is a plain character split: a
    /// multi-character key name ("F12") usually rides one side intact (⌃⌥⇧⌘F12 →
    /// ⌃⌥⇧ / ⌘F12), but the shortcut's modifier/key structure isn't visible here
    /// to guarantee it, so a short chord like ⌘F12 can divide it (⌘F / 12).
    private static func wrapped(_ text: String) -> String {
        guard text.count >= 4 else { return text }
        let split = text.index(text.startIndex, offsetBy: text.count / 2)
        return String(text[..<split]) + "\n" + String(text[split...])
    }
}

#Preview("Pad — standard") {
    KeyPadControl(platform: KeyboardApp(), isCompact: false)
        .environmentObject(
            AppController(sshClient: SSHClient(), platformRegistry: PlatformRegistry())
        )
        .preferredColorScheme(.dark)
}

#Preview("Pad — every cap shape") {
    KeyPadControl(platform: KeyboardApp(), isCompact: false, layoutStore: .preview(.glyphSampler))
        .environmentObject(
            AppController(sshClient: SSHClient(), platformRegistry: PlatformRegistry())
        )
        .preferredColorScheme(.dark)
}

/// Every cap shape at both pad sizes with no controller behind it — the
/// fastest place to iterate on key styling.
#Preview("Key caps") {
    let caps: [RemoteKey] = [
        .up, .space, .return,
        .escape, .tab, .delete,
        RemoteKey.withID("a")!, RemoteKey.withID("m")!, RemoteKey.withID("7")!,
        RemoteKey.withID("`")!, RemoteKey.withID("\\")!, RemoteKey.withID("f12")!,
    ]
    return ScrollView {
        VStack(spacing: 24) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(caps) { cap in
                    PadKeyButton(command: .key(cap)) {}
                }
            }
            Text("Compact (phone landscape)")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
                ForEach(caps) { cap in
                    PadKeyButton(command: .key(cap), size: 44, fontSize: 26) {}
                }
            }
        }
        .padding(24)
    }
    .preferredColorScheme(.dark)
}
