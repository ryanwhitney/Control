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
    /// False when paged away or under a sheet, which lowers the soft keyboard:
    /// its typing would otherwise reach the Mac from a page that isn't showing.
    var isVisible = true
    @EnvironmentObject var controller: AppController
    @ObservedObject var layoutStore: KeyPadLayoutStore = .shared
    @State private var isTyping = false
    @State private var typist = RemoteTypist()
    /// Bumped by pad presses while typing: they move the Mac's caret, so the
    /// keyboard's copy of what was typed has to start over.
    @State private var keyboardContext = 0

    /// Uniform within and between zones, so the pad reads as one grid. The whole
    /// gap lives here — caps carry no padding — so the sizing below is exact.
    private var spacing: CGFloat { isCompact ? 14 : 16 }

    var body: some View {
        pad
            .background {
                SoftKeyboardInput(isActive: $isTyping, contextVersion: keyboardContext) { edits in
                    typist.send(.typing(edits), via: perform)
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .onChange(of: isVisible) { _, visible in
                if !visible { isTyping = false }
            }
            .onDisappear {
                isTyping = false
            }
    }

    @ViewBuilder
    private var pad: some View {
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
            ForEach(Array(layoutStore.layout.utility.cells.enumerated()), id: \.offset) { _, cell in
                cellView(cell, capSize: capSize)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: PadCell?, capSize: CGFloat) -> some View {
        if let cell {
            cellButton(cell, capSize: capSize)
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

    private func cellButton(_ cell: PadCell, capSize: CGFloat) -> some View {
        let isKeyboardToggle = cell.command == .softKeyboard
        return PadKeyButton(cell: cell, size: capSize, fontSize: glyphFontSize(for: capSize), isOn: isKeyboardToggle && isTyping) {
            guard let action = cell.action else {
                if isKeyboardToggle { isTyping.toggle() }
                return
            }
            if isTyping {
                // Behind any typing still on its way, or an arrow could land
                // before the text it was meant to move through.
                keyboardContext += 1
                typist.send(action, via: perform)
            } else {
                // Independent, so a run of presses is limited only by the
                // connection. `updateState`'s 2 s dedupe caps the refreshes.
                Task {
                    await perform(action)
                }
            }
            Task {
                await controller.updateState(for: platform)
            }
        }
    }
}

extension KeyPadControl {
    private func perform(_ action: AppAction) async {
        await controller.executeActionWithoutStatus(platform: platform, action: action)
    }
}

/// One live pad key. Takes no controller or store, so the "Key caps" preview
/// can render every shape directly.
struct PadKeyButton: View {
    let cell: PadCell
    var size: CGFloat = 60
    var fontSize: CGFloat = 36
    /// A toggle cap's on state: the soft keyboard is up.
    var isOn = false
    let action: () -> Void

    /// The keyboard symbol is wide and dense, so at full size it outweighs the
    /// letter caps beside it. A custom icon in its place keeps the usual size.
    private var bareGlyphScale: CGFloat {
        cell.command == .softKeyboard && cell.drawableIcon == nil ? 0.8 : 1
    }

    var body: some View {
        Button(action: action) {
            if let hint = cell.keyHint {
                // Smaller than a bare glyph, so the icon and hint together
                // still fit the cap.
                VStack(spacing: size * 0.04) {
                    KeyCapGlyph(glyph: cell.glyph)
                        .font(.system(size: fontSize * 0.7))
                    Text(hint)
                        .font(.system(size: max(10, size * 0.15), weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            } else {
                // By font, not a resizable frame: these glyphs don't share an
                // aspect ratio, and a uniform square renders the wide ones tiny.
                KeyCapGlyph(glyph: cell.glyph, wrapsLongText: true)
                    .font(.system(size: fontSize * bareGlyphScale))
            }
        }
        // Don't pad: a cap's footprint must stay exactly `size` — the pad's
        // sizing and its empty-cell placeholders assume it.
        .buttonStyle(IconButtonStyle(width: size, height: size, fontSize: fontSize))
        .background(RoundedRectangle(cornerRadius: 20).fill(.tint.opacity(isOn ? 0.2 : 0)))
        .animation(.easeOut(duration: 0.12), value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(cell.label)
        .accessibilityInputLabels(cell.inputLabels)
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

/// Sends soft-keyboard typing in order, one command in flight. Whatever is
/// typed meanwhile is merged into the next send, so fast typing costs fewer
/// round trips and never overflows the channel's bounded queue — independent
/// sends could drop keys there, or land out of order. Pad presses made while
/// typing join the same line.
@MainActor
final class RemoteTypist {
    /// Bounds one command's script, which `textStatements` splits into lines.
    private static let maxTextPerSend = 500

    private var pending: [AppAction] = []
    private var isSending = false

    func send(_ action: AppAction, via perform: @escaping (AppAction) async -> Void) {
        if case .typing(let edits) = action, case .typing(let queued)? = pending.last {
            pending[pending.count - 1] = .typing(Self.merged(queued + edits))
        } else {
            pending.append(action)
        }
        guard !isSending else { return }
        isSending = true
        Task {
            while let next = takeNext() {
                await perform(next)
            }
            isSending = false
        }
    }

    private func takeNext() -> AppAction? {
        guard !pending.isEmpty else { return nil }
        let first = pending.removeFirst()
        guard case .typing(let edits) = first else { return first }
        let (head, rest) = Self.split(edits, maxText: Self.maxTextPerSend)
        if !rest.isEmpty { pending.insert(.typing(rest), at: 0) }
        return .typing(head)
    }

    /// Joins neighbours of a kind, and nets opposing arrow runs, which have no
    /// effect but the caret's position.
    nonisolated static func merged(_ edits: [TypingEdit]) -> [TypingEdit] {
        var result: [TypingEdit] = []
        for edit in edits {
            guard let last = result.last else {
                result.append(edit)
                continue
            }
            switch (last, edit) {
            case (.text(let a), .text(let b)):
                result[result.count - 1] = .text(a + b)
            case (.deleteBackward(let a), .deleteBackward(let b)):
                result[result.count - 1] = .deleteBackward(a + b)
            case (.moveLeft(let a), .moveLeft(let b)):
                result[result.count - 1] = .moveLeft(a + b)
            case (.moveRight(let a), .moveRight(let b)):
                result[result.count - 1] = .moveRight(a + b)
            case (.moveLeft(let a), .moveRight(let b)), (.moveRight(let b), .moveLeft(let a)):
                // Net leftward steps; which case matched decides the sign.
                let left = a - b
                result.removeLast()
                if left > 0 { result.append(.moveLeft(left)) }
                if left < 0 { result.append(.moveRight(-left)) }
            default:
                result.append(edit)
            }
        }
        return result
    }

    /// The first edits holding at most `maxText` characters, splitting a long
    /// text by Character so a CRLF or an emoji is never cut.
    nonisolated static func split(_ edits: [TypingEdit], maxText: Int) -> (head: [TypingEdit], rest: [TypingEdit]) {
        var head: [TypingEdit] = []
        var budget = maxText
        for (index, edit) in edits.enumerated() {
            guard case .text(let text) = edit else {
                head.append(edit)
                continue
            }
            if text.count <= budget {
                head.append(edit)
                budget -= text.count
                continue
            }
            let taken = String(text.prefix(budget))
            if !taken.isEmpty { head.append(.text(taken)) }
            let rest = [TypingEdit.text(String(text.dropFirst(taken.count)))] + edits[(index + 1)...]
            return (head, Array(rest))
        }
        return (head, [])
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
                    PadKeyButton(cell: .key(cap)) {}
                }
            }
            Text("Compact (phone landscape)")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
                ForEach(caps) { cap in
                    PadKeyButton(cell: .key(cap), size: 44, fontSize: 26) {}
                }
            }
        }
        .padding(24)
    }
    .preferredColorScheme(.dark)
}
