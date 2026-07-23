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
    /// Multiplies the portrait cap (and its glyph) so the pad grows on iPad, where
    /// there's the room. 1 on phones. Landscape sizes caps to the granted height
    /// instead, so this only affects the portrait path.
    var sizeScale: CGFloat = 1
    @EnvironmentObject var controller: AppController
    /// Injectable so previews can render arbitrary layouts; defaults to the
    /// persisted store.
    @ObservedObject var layoutStore: KeyPadLayoutStore = .shared

    /// The gap between caps — uniform within a zone and between the utility strip
    /// and the pad, so the live pad reads as one grid. (The editor adds its own
    /// extra separation between the two zones; the pad itself doesn't.)
    private var spacing: CGFloat { isCompact ? 6 : 8 }

    var body: some View {
        if isCompact {
            // Landscape sizes the caps to fill the height the page grants.
            GeometryReader { proxy in
                let capSize = compactCapSize(in: proxy.size)
                HStack(spacing: spacing) {
                    utilityColumn(capSize: capSize)
                    zoneGrid(layoutStore.layout.pad, capSize: capSize)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            // Portrait keeps the pad at its natural height so the pager's spacers
            // can centre it in the page.
            VStack(spacing: spacing) {
                zoneGrid(layoutStore.layout.utility, capSize: portraitCapSize)
                zoneGrid(layoutStore.layout.pad, capSize: portraitCapSize)
            }
        }
    }

    /// Fixed rather than space-filling: portrait centres a natural-height pad via
    /// the pager's spacers, so the pad must report a real height. 84pt clears the
    /// volume row on the smallest phones' four-row layout; iPad scales it up via
    /// `sizeScale`, where there's room to spare.
    private var portraitCapSize: CGFloat { 84 * sizeScale }

    /// The largest cap the granted space can hold, clamped to 44–100pt (44 is the
    /// tap-target minimum). Landscape lays out one utility column beside the pad's
    /// columns, so both axes are `count` caps with `count - 1` gaps: height against
    /// the taller zone's rows, width against the utility column plus the pad's
    /// columns.
    private func compactCapSize(in available: CGSize) -> CGFloat {
        let pad = layoutStore.layout.pad
        let utilityCount = layoutStore.layout.utility.cells.count
        let rows = CGFloat(max(pad.rowCount, utilityCount, 1))
        let heightDriven = (available.height - (rows - 1) * spacing) / rows
        let columns = CGFloat(pad.columns + 1)
        let widthDriven = (available.width - (columns - 1) * spacing) / columns
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
                .clipShape(RoundedRectangle(cornerRadius: 20.0))
        } else {
            // Sized, not `gridCellUnsizedAxes`: a fully empty row or column
            // must keep its footprint so key positions stay where the editor
            // shows them.
            Color.clear.frame(width: capSize, height: capSize)
        }
    }

    /// The glyph point size for a cap: 60% of the cap, capped at 50pt so the widest
    /// symbols (space, return — sized by point size, not fit to the cap) stay
    /// bounded at the largest landscape caps. The cap scales with `sizeScale` so an
    /// iPad's larger caps keep their glyphs in proportion. The one control for
    /// live-cap glyph size; `PadKeyButton`'s `fontSize` default applies only to
    /// previews.
    private func glyphFontSize(for capSize: CGFloat) -> CGFloat {
        min(capSize * 0.6, 50 * sizeScale)
    }

    private func commandButton(_ command: PadCommand, capSize: CGFloat) -> some View {
        PadKeyButton(command: command, size: capSize, fontSize: glyphFontSize(for: capSize)) {
            // Two independent tasks: the key press sends with no status read
            // behind it, so a run of presses is limited only by the connection,
            // and the readout refresh runs alongside it rather than after.
            // `updateState`'s 2 s dedupe keeps a burst from queueing a refresh
            // per press.
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
            // Sized by font rather than a resizable frame: these glyphs don't
            // share an aspect ratio (arrows are square, space/return are wide and
            // short), so forcing them into a uniform square would render the wide
            // ones (space) very small.
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
    /// second glyph, so it stays legible in the square cap rather than shrinking
    /// too small on one line. The editor and picker keep one line — they caption
    /// the chord in full beneath the cap.
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

    /// Splits a 4-or-more-glyph chord across two lines, shorter half first
    /// (4 → 2+2, 5 → 2+3); shorter caps stay on one line. A plain character split,
    /// so a multi-character key name can land across the break (⌘F12 → ⌘F / 12) —
    /// acceptable, since the modifier/key structure to split on isn't visible here.
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
