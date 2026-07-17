import SwiftUI

/// The generic key pad, rendered from the user's `KeyPadLayout`: a fixed grid
/// whose filled cells send their key to whatever app is frontmost on the Mac
/// (see `KeyboardApp`) and whose empty cells hold their place, so the pad's
/// shape always matches its editor's.
struct KeyPadControl: View {
    let platform: any AppPlatform
    /// Phone landscape: the same grid, drawn tighter — four full-size rows
    /// don't fit under the title and readout there. (A separately arranged
    /// landscape layout is a possible follow-up; for now the grid is uniform.)
    let isCompact: Bool
    @EnvironmentObject var controller: AppController
    /// Injectable so previews can render arbitrary layouts; defaults to the
    /// persisted store.
    @ObservedObject var layoutStore: KeyPadLayoutStore = .shared

    private var spacing: CGFloat { isCompact ? 6 : 8 }
    private var buttonSize: CGFloat { isCompact ? 44 : 60 }
    private var fontSize: CGFloat { isCompact ? 26 : 36 }

    var body: some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(0..<KeyPadLayout.rowCount, id: \.self) { row in
                GridRow {
                    ForEach(0..<KeyPadLayout.columnCount, id: \.self) { column in
                        if let command = layoutStore.layout[row: row, column: column] {
                            commandButton(command)
                        } else {
                            // Sized, not `gridCellUnsizedAxes`: a fully empty
                            // row or column must keep its footprint so key
                            // positions stay where the editor shows them.
                            Color.clear.frame(width: buttonSize, height: buttonSize)
                        }
                    }
                }
            }
        }
    }

    private func commandButton(_ command: PadCommand) -> some View {
        PadKeyButton(command: command, size: buttonSize, fontSize: fontSize) {
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
            KeyCapGlyph(glyph: command.glyph)
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

    var body: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
        case .character(let text):
            Text(text)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
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
