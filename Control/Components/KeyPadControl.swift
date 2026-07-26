import SwiftUI

/// The key pad, drawn from the user's `KeyPadLayout` zones. Empty cells hold
/// their place so the shape always matches the editor's.
struct KeyPadControl: View {
    let platform: any AppPlatform
    /// Landscape: the utility strip pivots to a column beside the pad, which
    /// keeps its directionally-meaningful shape.
    let isCompact: Bool
    /// Grows the portrait cap on iPad. 1 on phones, and unused in landscape,
    /// which sizes caps to the granted height instead.
    var sizeScale: CGFloat = 1
    @EnvironmentObject var controller: AppController
    @ObservedObject var layoutStore: KeyPadLayoutStore = .shared

    /// Uniform within and between zones, so the pad reads as one grid. The whole
    /// gap lives here — caps carry no padding — so the sizing below is exact.
    private var spacing: CGFloat { isCompact ? 14 : 16 }

    var body: some View {
        if isCompact {
            GeometryReader { proxy in
                let capSize = compactCapSize(in: proxy.size)
                HStack(spacing: spacing) {
                    utilityColumn(capSize: capSize)
                    zoneGrid(layoutStore.layout.pad, capSize: capSize)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            VStack(spacing: spacing) {
                zoneGrid(layoutStore.layout.utility, capSize: portraitCapSize)
                zoneGrid(layoutStore.layout.pad, capSize: portraitCapSize)
            }
        }
    }

    /// Fixed, so portrait can centre a pad of real height. 84pt clears the volume
    /// row on the smallest phones' four-row layout.
    private var portraitCapSize: CGFloat { 84 * sizeScale }

    /// The largest cap the granted space holds, clamped to 44–100pt (44 is the
    /// tap-target minimum). Both axes are `count` caps with `count - 1` gaps.
    private func compactCapSize(in available: CGSize) -> CGFloat {
        let pad = layoutStore.layout.pad
        let utilityCount = layoutStore.layout.utility.cells.count
        let rows = CGFloat(max(pad.rowCount, utilityCount, 1))
        let heightDriven = (available.height - (rows - 1) * spacing) / rows
        let columns = CGFloat(pad.columns + 1)
        let widthDriven = (available.width - (columns - 1) * spacing) / columns
        return min(max(44, min(heightDriven, widthDriven)), 100)
    }

    /// At its *stored* dimensions, so data from a version with wider zones
    /// still renders.
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
            // Sized, not `gridCellUnsizedAxes`: an empty row or column must
            // keep its footprint or key positions shift from the editor's.
            Color.clear.frame(width: capSize, height: capSize)
        }
    }

    /// 60% of the cap, capped so the widest symbols (space, return) stay bounded
    /// at the largest caps. The one control for live-cap glyph size.
    private func glyphFontSize(for capSize: CGFloat) -> CGFloat {
        min(capSize * 0.6, 50 * sizeScale)
    }

    private func commandButton(_ command: PadCommand, capSize: CGFloat) -> some View {
        PadKeyButton(command: command, size: capSize, fontSize: glyphFontSize(for: capSize)) {
            // Independent, so a run of presses is limited only by the
            // connection. `updateState`'s 2 s dedupe caps the refreshes.
            Task {
                await controller.executeActionWithoutStatus(platform: platform, action: command.action)
            }
            Task {
                await controller.updateState(for: platform)
            }
        }
    }
}

/// One live pad key. Takes no controller or store, so the "Key caps" preview
/// can render every shape directly.
struct PadKeyButton: View {
    let command: PadCommand
    var size: CGFloat = 60
    var fontSize: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // By font, not a resizable frame: these glyphs don't share an aspect
            // ratio, and a uniform square renders the wide ones tiny.
            KeyCapGlyph(glyph: command.glyph, wrapsLongText: true)
                .accessibilityLabel(command.label)
        }
        // Don't pad: a cap's footprint must stay exactly `size` — the pad's
        // sizing and its empty-cell placeholders assume it.
        .buttonStyle(IconButtonStyle(width: size, height: size, fontSize: fontSize))
        .accessibilityInputLabels(command.inputLabels)
    }
}

/// A cell's key cap, as the pad and the editor both draw it. Font size comes
/// from the enclosing view; multi-character caps scale down rather than clip.
struct KeyCapGlyph: View {
    let glyph: RemoteKey.Glyph
    /// The live pad wraps a long chord onto a second line to stay legible in a
    /// square cap. The editor and picker caption the chord in full instead.
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

    /// Shorter half first (4 → 2+2, 5 → 2+3). A plain character split, so a key
    /// name can land across the break (⌘F12 → ⌘F / 12) — the structure to split
    /// on isn't visible here.
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
