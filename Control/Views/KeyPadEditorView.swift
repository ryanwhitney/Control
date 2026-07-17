import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// In-app drag payload for pad cells; never leaves the app.
    static let padCell = UTType(exportedAs: "ryanwhitney.MacControl.padcell")
}

/// Drag payload: the cell a drag started from.
private struct DraggedCell: Codable, Transferable {
    let index: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .padCell)
    }
}

/// Edits the generic key pad's layout: the same grid the pad shows, at a more
/// deliberate size — filled cells captioned, empty cells drawn as sockets.
/// Tapping a cell chooses what goes there; dragging a cap onto another cell
/// trades places with it, and dragging onto the zone below removes it. Backed
/// by the shared `KeyPadLayoutStore`, so the pad behind the sheet updates as
/// you edit.
struct KeyPadEditorView: View {
    /// Injectable so previews can edit a throwaway layout; defaults to the
    /// persisted store.
    @ObservedObject var store: KeyPadLayoutStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var editingCell: EditingCell?
    @State private var confirmingReset = false
    /// The cell a drag is currently hovering, for its highlight ring.
    @State private var dropTargetIndex: Int?
    @State private var removeZoneTargeted = false

    /// Identifiable wrapper so a cell index can drive `navigationDestination(item:)`.
    private struct EditingCell: Identifiable, Hashable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: KeyPadLayout.columnCount
                        ),
                        spacing: 12
                    ) {
                        ForEach(0..<KeyPadLayout.cellCount, id: \.self) { index in
                            cellButton(at: index)
                        }
                    }
                    removeDropZone
                }
                .padding(20)
            }
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
    }

    private func cellButton(at index: Int) -> some View {
        let command = store.layout.cells[index]
        let button = Button {
            editingCell = EditingCell(index: index)
        } label: {
            KeyCapCell(command: command, isSelected: dropTargetIndex == index)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(command?.label ?? "Empty space")
        // The grid is positional, so VoiceOver needs the coordinates sighted
        // users get from the layout.
        .accessibilityValue("Row \(index / KeyPadLayout.columnCount + 1), column \(index % KeyPadLayout.columnCount + 1)")
        .accessibilityHint("Chooses the key for this space")

        return Group {
            if command != nil {
                button.draggable(DraggedCell(index: index))
            } else {
                button
            }
        }
        .dropDestination(for: DraggedCell.self) { dropped, _ in
            guard let source = dropped.first, source.index != index else { return false }
            // Swap, not insert: dropping on a filled cell trades places with
            // it, so a drag can never push other keys around the fixed grid.
            store.layout.cells.swapAt(source.index, index)
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetIndex = index
            } else if dropTargetIndex == index {
                dropTargetIndex = nil
            }
        }
    }

    /// Always visible while editing, so the drag-to-remove gesture is
    /// discoverable; destructive red only while a drag hovers it.
    private var removeDropZone: some View {
        Label("Drag here to remove", systemImage: "trash")
            .font(.callout)
            .foregroundStyle(removeZoneTargeted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.red.opacity(removeZoneTargeted ? 0.15 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        removeZoneTargeted ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
            .dropDestination(for: DraggedCell.self) { dropped, _ in
                guard let source = dropped.first else { return false }
                store.layout.cells[source.index] = nil
                return true
            } isTargeted: { removeZoneTargeted = $0 }
            .animation(.easeInOut(duration: 0.15), value: removeZoneTargeted)
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
                .fill(command == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary))
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
