import SwiftUI
import UIKit

/// Edits the generic key pad's layout: the same grid the pad shows, at a more
/// deliberate size — filled cells captioned, empty cells drawn as sockets.
/// Tapping a cell chooses what goes there. Holding a cap lifts the real thing
/// out of its cell (the socket stays behind), hovering marks the drop target,
/// releasing springs the caps through a swap — or back home if nothing valid
/// is under the finger — and a remove zone fades in below while a cap is up.
///
/// The drag is a custom long-press + drag gesture rather than
/// `.draggable`/`.dropDestination`: the system API drags a detached preview
/// copy, offers no lift/cancel hooks to reveal the remove zone or hollow the
/// source cell, and won't register drops on transparent (empty) cells. Here
/// the lifted cap is an overlay in the editor's coordinate space, and
/// targeting is plain rect hit-testing against measured cell frames.
struct KeyPadEditorView: View {
    /// Injectable so previews can edit a throwaway layout; defaults to the
    /// persisted store.
    @ObservedObject var store: KeyPadLayoutStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var editingCell: EditingCell?
    @State private var confirmingReset = false

    // MARK: Drag state

    private enum DropTarget: Equatable {
        case cell(Int)
        case remove
    }

    private struct DragState {
        let sourceIndex: Int
        let command: PadCommand
        /// Keeps the cap under the same point of the finger that grabbed it.
        var grabOffset: CGSize?
        var target: DropTarget?
        /// Set on release: the settle animation owns the overlay now, so late
        /// gesture events must not move it.
        var isSettling = false
    }

    private struct DisplacedCap {
        /// The grid index whose cap is mid-flight (hidden in the grid while
        /// its overlay flies to the source cell).
        let index: Int
        let command: PadCommand
    }

    @State private var drag: DragState?
    @State private var displaced: DisplacedCap?
    @State private var liftedCenter: CGPoint = .zero
    @State private var displacedCenter: CGPoint = .zero
    @State private var liftedScale: CGFloat = 1
    @State private var liftedOpacity: Double = 1
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var removeZoneFrame: CGRect = .zero

    private static let editorSpace = "keyPadEditor"
    private static let settleSpring = Animation.spring(response: 0.35, dampingFraction: 0.75)

    /// Identifiable wrapper so a cell index can drive `navigationDestination(item:)`.
    private struct EditingCell: Identifiable, Hashable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ZStack {
                    VStack(spacing: 16) {
                        cellGrid
                        removeDropZone
                    }
                    liftedOverlays
                }
                .coordinateSpace(name: Self.editorSpace)
                .padding(20)
            }
            .scrollDisabled(drag != nil)
            .navigationTitle("Edit Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        confirmingReset = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Reset to the standard layout?",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    store.reset()
                }
            }
            .navigationDestination(item: $editingCell) { cell in
                KeyPickerView(store: store, cellIndex: cell.index)
            }
        }
        .interactiveDismissDisabled(drag != nil)
    }

    // MARK: Grid

    private var cellGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: KeyPadLayout.columnCount
            ),
            spacing: 12
        ) {
            ForEach(0..<KeyPadLayout.cellCount, id: \.self) { index in
                cell(at: index)
            }
        }
    }

    private func cell(at index: Int) -> some View {
        let command = store.layout.cells[index]
        // The lifted cap's cell and a mid-swap target both show the empty
        // socket: their caps are rendered by the overlays instead.
        let capIsAirborne = drag?.sourceIndex == index || displaced?.index == index
        let isHovered = drag?.target == .cell(index)
        return KeyCapCell(command: capIsAirborne ? nil : command, isSelected: isHovered, capIsAirborne: capIsAirborne)
            // Explicit shape so taps and drop targeting work on empty cells,
            // whose transparent fill isn't hit-testable on its own.
            .contentShape(.rect(cornerRadius: 14))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.editorSpace))
            } action: { frame in
                cellFrames[index] = frame
            }
            .onTapGesture {
                guard drag == nil else { return }
                editingCell = EditingCell(index: index)
            }
            .gesture(cellDragGesture(for: index))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(command?.label ?? "Empty space")
            // The grid is positional, so VoiceOver needs the coordinates
            // sighted users get from the layout.
            .accessibilityValue("Row \(index / KeyPadLayout.columnCount + 1), column \(index % KeyPadLayout.columnCount + 1)")
            .accessibilityHint("Chooses the key for this space")
            .accessibilityAction {
                editingCell = EditingCell(index: index)
            }
    }

    /// The caps in flight, drawn in the editor's coordinate space above the
    /// grid: the lifted cap under the finger, and — during a swap settle —
    /// the displaced cap flying to the vacated cell.
    @ViewBuilder
    private var liftedOverlays: some View {
        if let drag {
            KeyCapCell(command: drag.command)
                .frame(width: cellFrames[drag.sourceIndex]?.width)
                .scaleEffect(liftedScale)
                .opacity(liftedOpacity)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .position(liftedCenter)
                .allowsHitTesting(false)
        }
        if let displaced {
            KeyCapCell(command: displaced.command)
                .frame(width: cellFrames[displaced.index]?.width)
                .position(displacedCenter)
                .allowsHitTesting(false)
        }
    }

    /// Only visible while a cap is lifted — but always laid out, so revealing
    /// it never shifts the grid mid-drag (the cell frames the hit-testing
    /// depends on must not move).
    private var removeDropZone: some View {
        let isTargeted = drag?.target == .remove
        return Label("Drag here to remove", systemImage: "trash")
            .font(.callout)
            .foregroundStyle(isTargeted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.red.opacity(isTargeted ? 0.15 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isTargeted ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.editorSpace))
            } action: { frame in
                removeZoneFrame = frame
            }
            .opacity(drag == nil ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: drag == nil)
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .accessibilityHidden(true)
    }

    // MARK: Drag mechanics

    private func cellDragGesture(for index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.editorSpace)))
            .onChanged { value in
                guard case .second(true, let dragValue) = value else { return }
                if drag == nil {
                    beginDrag(from: index)
                }
                if let dragValue {
                    updateDrag(with: dragValue)
                }
            }
            .onEnded { value in
                if case .second(true, _) = value {
                    endDrag()
                } else {
                    // Long press never completed (or the system cancelled the
                    // sequence); if a cap did lift, float it home.
                    settleBack()
                }
            }
    }

    private func beginDrag(from index: Int) {
        guard drag == nil,
              let command = store.layout.cells[index],
              let frame = cellFrames[index] else { return }
        drag = DragState(sourceIndex: index, command: command)
        liftedCenter = frame.center
        liftedScale = 1
        liftedOpacity = 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            liftedScale = 1.08
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func updateDrag(with value: DragGesture.Value) {
        guard var drag, !drag.isSettling else { return }
        if drag.grabOffset == nil, let frame = cellFrames[drag.sourceIndex] {
            drag.grabOffset = CGSize(
                width: frame.midX - value.startLocation.x,
                height: frame.midY - value.startLocation.y
            )
        }
        let offset = drag.grabOffset ?? .zero
        liftedCenter = CGPoint(x: value.location.x + offset.width, y: value.location.y + offset.height)
        // Targeting follows the finger, not the cap's centre — standard drop
        // behaviour, and it keeps working when the grab point is off-centre.
        let target = dropTarget(at: value.location, sourceIndex: drag.sourceIndex)
        if target != drag.target {
            UISelectionFeedbackGenerator().selectionChanged()
            drag.target = target
        }
        self.drag = drag
    }

    private func dropTarget(at point: CGPoint, sourceIndex: Int) -> DropTarget? {
        if removeZoneFrame.contains(point) {
            return .remove
        }
        for (index, frame) in cellFrames where frame.contains(point) {
            // The source cell is "nowhere": releasing there settles the cap
            // back rather than swapping with itself.
            return index == sourceIndex ? nil : .cell(index)
        }
        return nil
    }

    private func endDrag() {
        guard var drag, !drag.isSettling else { return }
        drag.isSettling = true
        self.drag = drag

        switch drag.target {
        case .cell(let targetIndex):
            let sourceIndex = drag.sourceIndex
            if let displacedCommand = store.layout.cells[targetIndex],
               let targetFrame = cellFrames[targetIndex],
               let sourceFrame = cellFrames[sourceIndex] {
                displaced = DisplacedCap(index: targetIndex, command: displacedCommand)
                displacedCenter = targetFrame.center
                withAnimation(Self.settleSpring) {
                    displacedCenter = sourceFrame.center
                }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Self.settleSpring, completionCriteria: .logicallyComplete) {
                if let targetFrame = cellFrames[targetIndex] {
                    liftedCenter = targetFrame.center
                }
                liftedScale = 1
            } completion: {
                // Commit and clear in the same transaction: the grid takes
                // over exactly where the overlays stopped, so nothing jumps.
                store.layout.cells.swapAt(sourceIndex, targetIndex)
                finishDrag()
            }
        case .remove:
            let sourceIndex = drag.sourceIndex
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
                liftedScale = 0.3
                liftedOpacity = 0
            } completion: {
                store.layout.cells[sourceIndex] = nil
                finishDrag()
            }
        case nil:
            settleBack()
        }
    }

    /// Floats the lifted cap back to its own cell — no valid target under the
    /// finger, or the drag was cancelled.
    private func settleBack() {
        guard var drag else { return }
        drag.isSettling = true
        self.drag = drag
        withAnimation(Self.settleSpring, completionCriteria: .logicallyComplete) {
            if let frame = cellFrames[drag.sourceIndex] {
                liftedCenter = frame.center
            }
            liftedScale = 1
        } completion: {
            finishDrag()
        }
    }

    private func finishDrag() {
        drag = nil
        displaced = nil
        liftedScale = 1
        liftedOpacity = 1
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

/// Chooses the key for one pad cell: the full unmodified keyboard, grouped
/// into sections and drawn as key caps. Selecting pops back to the grid;
/// Remove empties the cell.
private struct KeyPickerView: View {
    @ObservedObject var store: KeyPadLayoutStore
    let cellIndex: Int
    @Environment(\.dismiss) private var dismiss

    private var current: PadCommand? {
        store.layout.cells[cellIndex]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(RemoteKey.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                            ForEach(section.keys) { key in
                                keyButton(key)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Choose Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if current != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Remove", role: .destructive) {
                        store.layout.cells[cellIndex] = nil
                        dismiss()
                    }
                    // The app's theme tint colors toolbar items; removal must
                    // read as destructive regardless of theme.
                    .tint(.red)
                }
            }
        }
    }

    private func keyButton(_ key: RemoteKey) -> some View {
        let isSelected = current == .key(key)
        return Button {
            store.layout.cells[cellIndex] = .key(key)
            dismiss()
        } label: {
            KeyCapCell(command: .key(key), isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One key cap tile: glyph centred, captioned beneath for SF Symbol keys (an
/// arrow glyph doesn't name itself; "A" does), a dashed socket when empty.
/// `isSelected` draws the tint ring — the picker's current key, or the cell a
/// drag is hovering.
private struct KeyCapCell: View {
    let command: PadCommand?
    var isSelected: Bool = false
    var capIsAirborne: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let command {
                    KeyCapGlyph(glyph: command.glyph)
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "plus")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 28))
            .frame(height: 34)

            if let command, case .symbol = command.glyph {
                Text(command.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(command == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
                
                
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary),
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2 : 1,
                        dash: command == nil ? [5, 4] : []
                    )
                )
                .opacity(command == nil || isSelected ? 1 : 0)
        )
    }
}

#Preview("Editor — standard") {
    KeyPadEditorView(store: .preview())
        .preferredColorScheme(.dark)
}

#Preview("Editor — every cap shape") {
    KeyPadEditorView(store: .preview(.glyphSampler))
        .preferredColorScheme(.dark)
}

/// Each visual state of an editor tile side by side — the place to iterate on
/// tile styling.
#Preview("Editor cells") {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
        KeyCapCell(command: .key(.escape))
        KeyCapCell(command: .key(RemoteKey.withID("a")!))
        KeyCapCell(command: .key(RemoteKey.withID("f12")!))
        KeyCapCell(command: .key(RemoteKey.withID("\\")!))
        KeyCapCell(command: .key(.space), isSelected: true)
        KeyCapCell(command: nil)
    }
    .padding(24)
    .preferredColorScheme(.dark)
}

#Preview("Key picker") {
    NavigationStack {
        KeyPickerView(store: .preview(.glyphSampler), cellIndex: 4)
    }
    .preferredColorScheme(.dark)
}
