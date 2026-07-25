import SwiftUI
import UIKit
import MultiBlur

/// The editor in its own stack, Done leading because the content's More menu
/// owns the trailing slot. Preferences pushes `KeyPadEditorContent` directly.
struct KeyPadEditorView: View {
    var store: KeyPadLayoutStore = .shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            KeyPadEditorContent(store: store)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
    }
}

/// Edits the key pad's layout: tap a cell to choose its key, hold to drag one
/// between cells, drop on the remove zone to clear it.
///
/// Hand-rolled long-press + drag rather than `.draggable`/`.dropDestination`:
/// the system API drags a detached preview copy, offers no lift/cancel hooks
/// for the remove zone, and won't register drops on transparent (empty) cells.
struct KeyPadEditorContent: View {
    @ObservedObject var store: KeyPadLayoutStore = .shared
    /// Only from Preferences, where the user isn't already standing on a pad.
    var showsEnablementHint = false
    @State private var editingCell: CellAddress?
    @State private var confirmingReset = false
    
    // MARK: Drag state
    
    private enum DropTarget: Equatable {
        case cell(CellAddress)
        case remove
    }
    
    private struct DragState {
        let source: CellAddress
        let command: PadCommand
        /// Keeps the cap under the same point of the finger that grabbed it.
        var grabOffset: CGSize?
        var target: DropTarget?
        /// The settle animation owns the overlay; late gesture events must not.
        var isSettling = false
    }
    
    private struct DisplacedCap {
        /// Hidden in the grid while its overlay flies to the source cell.
        let address: CellAddress
        let command: PadCommand
    }
    
    /// Swaps the settle flights for instant commits. The drag itself is direct
    /// manipulation, so it stays.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    /// Returns VoiceOver to the edited cell when the picker closes, so its own
    /// label speaks the outcome instead of an announcement that can be clipped.
    @AccessibilityFocusState private var focusedCell: CellAddress?
    
    @State private var drag: DragState?
    @State private var displaced: DisplacedCap?
    @State private var liftedCenter: CGPoint = .zero
    @State private var displacedCenter: CGPoint = .zero
    @State private var liftedScale: CGFloat = 1
    @State private var liftedOpacity: Double = 1
    @State private var cellFrames: [CellAddress: CGRect] = [:]
    @State private var removeZoneFrame: CGRect = .zero
    /// `@GestureState`, so it clears itself the moment the touch ends.
    @GestureState private var pressedCell: CellAddress?
    
    private static let editorSpace = "keyPadEditor"
    private static let settleSpring = Animation.spring(response: 0.35, dampingFraction: 0.75)
    
    var body: some View {
        ScrollView {
            ZStack {
                VStack(spacing: 16) {
                    if showsEnablementHint {
                        enablementHint
                    }
                    zoneGrid(.utility)
                    zoneGrid(.pad)
                    // More than the in-grid gap, or the zones read as one 3×4.
                        .padding(.top, 12)
                    removeDropZone
                }
                liftedOverlays
            }
            .coordinateSpace(name: Self.editorSpace)
            .padding(20)
        }
        .scrollDisabled(drag != nil)
        .onChange(of: editingCell) { previous, current in
            // Backstop for VoiceOver focus, timed past the dismissal animation.
            if current == nil, let previous {
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    focusedCell = previous
                }
            }
        }
        .navigationTitle("Customize Keyboard Controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Restore Default Layout", role: .destructive) {
                        confirmingReset = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                // Must attach to the menu: from the outer scroll view this
                // presents detached, and as a mis-anchored popover on iPad.
                .confirmationDialog(
                    "Restore the default layout?",
                    isPresented: $confirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Restore", role: .destructive) {
                        store.reset()
                    }
                }
            }
        }
        .sheet(item: $editingCell) { address in
            KeyPickerView(store: store, address: address)
        }
        .interactiveDismissDisabled(drag != nil)
    }
    
    // MARK: Grid
    
    /// Drawn at its *stored* dimensions, so data from a version with wider
    /// zones still renders.
    private func zoneGrid(_ zone: PadZone) -> some View {
        let grid = store.layout[zone]
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: grid.columns
            ),
            spacing: 12
        ) {
            ForEach(0..<grid.cells.count, id: \.self) { index in
                cell(at: CellAddress(zone: zone, index: index))
            }
        }
    }
    
    private func cell(at address: CellAddress) -> some View {
        let command = store.layout[address]
        // Airborne = the real cap is an overlay in flight, so this cell draws
        // no glyph: the lift source, a displaced cap, or a settling target.
        let isSettling = drag?.isSettling ?? false
        let isSource = drag?.source == address
        let isDropTarget = drag?.target == .cell(address)
        let capIsAirborne = isSource
        || displaced?.address == address
        || (isDropTarget && isSettling)
        // Only while a chip is settling in, so it can't flash under the landing
        // chip. A freshly lifted source keeps its plus.
        let hidesPlus = isSettling && (
            isDropTarget || (isSource && (displaced != nil || drag?.target == nil))
        )
        let isHovered = isDropTarget && !isSettling
        // Interactive glass reacts through a presented sheet, so pressing the
        // picker's caps would light up the editor's beneath it.
        return KeyCapCell(command: capIsAirborne ? nil : command, isSelected: isHovered, hidesPlus: hidesPlus, isInteractive: editingCell == nil, isPressed: pressedCell == address)
        // An empty cell's transparent fill isn't hit-testable on its own.
            .contentShape(.rect(cornerRadius: 14))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.editorSpace))
            } action: { frame in
                cellFrames[address] = frame
            }
            .onTapGesture {
                guard drag == nil else { return }
                editingCell = address
            }
            .gesture(cellDragGesture(for: address))
        // Press feedback for empty sockets. A 0-distance drag flags touch-down
        // without claiming the tap or the lift.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressedCell) { _, state, _ in
                        if command == nil { state = address }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(command?.label ?? "Empty space")
        // The grid is positional; VoiceOver needs the coordinates sighted users
        // read off the layout.
            .accessibilityValue(store.layout.accessibilityPosition(of: address))
            .accessibilityHint("Chooses the key for this space")
            .accessibilityInputLabels(command?.inputLabels ?? ["Empty space"])
            .accessibilityAction {
                editingCell = address
            }
            .accessibilityActions {
                // Parity with drag-to-remove, which assistive tech can't do.
                if command != nil {
                    Button("Remove Key") {
                        store.layout[address] = nil
                        // Rotor actions give no feedback of their own.
                        AccessibilityNotification.Announcement("Key removed").post()
                    }
                }
            }
            .accessibilityFocused($focusedCell, equals: address)
    }
    
    /// The caps in flight, above the grid in the editor's coordinate space.
    @ViewBuilder
    private var liftedOverlays: some View {
        if let drag {
            KeyCapCell(command: drag.command)
                .frame(width: cellFrames[drag.source]?.width)
                .scaleEffect(liftedScale)
                .opacity(liftedOpacity)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .position(liftedCenter)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        if let displaced {
            KeyCapCell(command: displaced.command)
                .frame(width: cellFrames[displaced.address]?.width)
                .position(displacedCenter)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
    
    private var enablementHint: some View {
        Text("This updates your controls for all connections with Keyboard controls enabled.")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background{
                RoundedRectangle(cornerRadius: 14)
                    .foregroundStyle(.thinMaterial)
            }
            .padding(.bottom, 10)
    }
    
    /// Always laid out, only faded: revealing it must not shift the cell frames
    /// the hit-testing measures.
    private var removeDropZone: some View {
        let isTargeted = drag?.target == .remove
        return Label("Drag here to remove", systemImage: "trash")
            .font(.callout)
            .foregroundStyle(isTargeted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isTargeted ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial))
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
    
    private func cellDragGesture(for address: CellAddress) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.editorSpace)))
            .onChanged { value in
                guard case .second(true, let dragValue) = value else { return }
                if drag == nil {
                    beginDrag(from: address)
                }
                // A second finger long-pressing elsewhere runs this too.
                guard drag?.source == address, let dragValue else { return }
                updateDrag(with: dragValue)
            }
            .onEnded { value in
                guard drag?.source == address else { return }
                if case .second(true, _) = value {
                    endDrag()
                } else {
                    settleBack()
                }
            }
    }
    
    private func beginDrag(from address: CellAddress) {
        guard drag == nil,
              let command = store.layout[address],
              let frame = cellFrames[address] else { return }
        drag = DragState(source: address, command: command)
        liftedCenter = frame.center
        liftedOpacity = 1
        if reduceMotion {
            liftedScale = 1.08
        } else {
            liftedScale = 1
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                liftedScale = 1.08
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func updateDrag(with value: DragGesture.Value) {
        guard var drag, !drag.isSettling else { return }
        if drag.grabOffset == nil, let frame = cellFrames[drag.source] {
            drag.grabOffset = CGSize(
                width: frame.midX - value.startLocation.x,
                height: frame.midY - value.startLocation.y
            )
        }
        let offset = drag.grabOffset ?? .zero
        liftedCenter = CGPoint(x: value.location.x + offset.width, y: value.location.y + offset.height)
        // Follows the finger, not the cap's centre, so an off-centre grab works.
        let target = dropTarget(at: value.location, source: drag.source)
        if target != drag.target {
            UISelectionFeedbackGenerator().selectionChanged()
            drag.target = target
        }
        self.drag = drag
    }
    
    private func dropTarget(at point: CGPoint, source: CellAddress) -> DropTarget? {
        if removeZoneFrame.contains(point) {
            return .remove
        }
        for (address, frame) in cellFrames where frame.contains(point) {
            // The source is "nowhere", so releasing there settles back.
            return address == source ? nil : .cell(address)
        }
        return nil
    }
    
    private func endDrag() {
        guard var drag, !drag.isSettling else { return }
        drag.isSettling = true
        self.drag = drag
        
        switch drag.target {
        case .cell(let target):
            let source = drag.source
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if reduceMotion {
                store.layout.swapCommands(source, target)
                finishDrag()
                return
            }
            if let displacedCommand = store.layout[target],
               let targetFrame = cellFrames[target],
               let sourceFrame = cellFrames[source] {
                displaced = DisplacedCap(address: target, command: displacedCommand)
                displacedCenter = targetFrame.center
                withAnimation(Self.settleSpring) {
                    displacedCenter = sourceFrame.center
                }
            }
            withAnimation(Self.settleSpring, completionCriteria: .logicallyComplete) {
                if let targetFrame = cellFrames[target] {
                    liftedCenter = targetFrame.center
                }
                liftedScale = 1
            } completion: {
                // Same transaction, so the grid takes over where the overlays
                // stopped and nothing jumps.
                store.layout.swapCommands(source, target)
                finishDrag()
            }
        case .remove:
            let source = drag.source
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            if reduceMotion {
                store.layout[source] = nil
                finishDrag()
                return
            }
            withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
                liftedScale = 0.3
                liftedOpacity = 0
            } completion: {
                store.layout[source] = nil
                finishDrag()
            }
        case nil:
            flyHome(to: drag.source)
        }
    }

    /// Floats the lifted cap back to its own cell — no valid target under the
    /// finger, or the drag was cancelled. Ignores a touch that ends mid-settle:
    /// restarting the flight would race the completion that commits the swap.
    private func settleBack() {
        guard var drag, !drag.isSettling else { return }
        drag.isSettling = true
        self.drag = drag
        flyHome(to: drag.source)
    }

    private func flyHome(to source: CellAddress) {
        if reduceMotion {
            finishDrag()
            return
        }
        withAnimation(Self.settleSpring, completionCriteria: .logicallyComplete) {
            if let frame = cellFrames[source] {
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

private extension KeyPadLayout {
    /// The two zones look alike to a swipe, so the name goes in the value.
    func accessibilityPosition(of address: CellAddress) -> String {
        let grid = self[address.zone]
        switch address.zone {
        case .utility:
            return "top row, position \(address.index + 1) of \(grid.cells.count)"
        case .pad:
            return "pad row \(address.index / grid.columns + 1), column \(address.index % grid.columns + 1)"
        }
    }
}

/// Chooses the key for one pad cell. A sheet rather than a push: a pop resets
/// VoiceOver focus to the top-left, a dismiss returns it to the edited cell.
private struct KeyPickerView: View {
    @ObservedObject var store: KeyPadLayoutStore
    let address: CellAddress
    @Environment(\.dismiss) private var dismiss
    
    private var current: PadCommand? {
        store.layout[address]
    }
    
    private var positionDescription: String {
        store.layout.accessibilityPosition(of: address)
    }
    
    @State private var showingShortcutBuilder = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    shortcutsSection
                    // Nothing on screen says what selecting does.
                    KeyCatalogGrid(
                        isSelected: { current == .key($0) },
                        accessibilityHint: "Assigns this key to \(positionDescription)"
                    ) { key in
                        assign(.key(key))
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
                            store.layout[address] = nil
                            dismiss()
                        }
                        // The theme tint colors toolbar items; this must stay red.
                        .tint(.red)
                    }
                }
            }
            .navigationDestination(isPresented: $showingShortcutBuilder) {
                ShortcutBuilderView(store: store, address: address) {
                    // The whole sheet, not just the pushed page.
                    dismiss()
                }
            }
        }
        .presentationBackground(.thickMaterial)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    private func assign(_ command: PadCommand) {
        store.layout[address] = command
        // Let the tap's selected state show; dismissing in the same instant
        // reads as a no-op.
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            dismiss()
        }
    }
    
    // MARK: Shortcuts row
    
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(store.availableShortcuts, id: \.contentID) { shortcut in
                    shortcutButton(shortcut)
                }
                newShortcutButton
            }
        }
    }
    
    private func shortcutButton(_ shortcut: KeyShortcut) -> some View {
        let command = PadCommand.shortcut(shortcut)
        // By content, not `==`: a hand-built chord is stored name-less and
        // wouldn't match the same chord as a preset.
        let isSelected: Bool
        if case .shortcut(let currentShortcut) = current {
            isSelected = currentShortcut.contentID == shortcut.contentID
        } else {
            isSelected = false
        }
        return Button {
            assign(command)
        } label: {
            KeyCapCell(command: command, isSelected: isSelected, usesGlass: false)
        }
        .buttonStyle(PickerKeyStyle())
        .contextMenu {
            // A preset is only hidden; a creation is dropped. Cells keep their
            // own copy either way.
            Button("Delete Shortcut", role: .destructive) {
                store.deleteShortcut(shortcut)
            }
        }
        .accessibilityLabel(shortcut.spokenText)
        .accessibilityHint("Assigns this shortcut to \(positionDescription)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    
    /// Glass rather than material, so it reads as an action not another cap.
    private var newShortcutButton: some View {
        Button {
            showingShortcutBuilder = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .foregroundStyle(.tint)
                    .font(.system(size: 28))
                    .frame(height: 34)
                Text("Add")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .glassRect()
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Shortcut")
        .accessibilityHint("Builds a key combination to assign")
    }
}

/// Surfaces the pressed flag through the environment so `KeyCapCell` can draw
/// the wash itself. No dim/scale — those read as sluggish on a tap-to-assign grid.
private struct PickerKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.keyTilePressed, configuration.isPressed)
    }
}

/// The sectioned key catalog, shared by the picker and the shortcut builder.
private struct KeyCatalogGrid: View {
    let isSelected: (RemoteKey) -> Bool
    let accessibilityHint: String
    let onTap: (RemoteKey) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(RemoteKey.sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.title)
                        .font(.headline)
                    // ~70 keys is too many to swipe without rotor section jumps.
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(section.keys) { key in
                            Button {
                                onTap(key)
                            } label: {
                                KeyCapCell(command: .key(key), isSelected: isSelected(key), usesGlass: false)
                            }
                            .buttonStyle(PickerKeyStyle())
                            .accessibilityLabel(key.label)
                            .accessibilityHint(accessibilityHint)
                            .accessibilityAddTraits(isSelected(key) ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }
}

/// Builds a chord: toggle the modifiers, pick the key, watch the cap preview
/// assemble, then Add — which assigns it to the cell being edited and files
/// it in the picker's Shortcuts row for reuse.
private struct ShortcutBuilderView: View {
    @ObservedObject var store: KeyPadLayoutStore
    let address: CellAddress
    /// Dismisses the whole picker sheet; popping back alone strands the user.
    let onAssigned: () -> Void
    
    /// ⌘ pre-armed: every shortcut needs a modifier and ⌘ is most of them.
    @State private var modifiers: Set<KeyModifier> = [.command]
    @State private var selectedKey: RemoteKey?
    
    private var builtShortcut: KeyShortcut? {
        guard let selectedKey, !modifiers.isEmpty else { return nil }
        return KeyShortcut(name: nil, presses: [KeyPress(key: selectedKey, modifiers: Array(modifiers))])
    }
    
    private var orderedModifiers: [KeyModifier] {
        KeyModifier.allCases.filter(modifiers.contains)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                chordPreview
                
                modifierChips
                
                KeyCatalogGrid(
                    isSelected: { selectedKey?.id == $0.id },
                    accessibilityHint: "Selects this key for the shortcut"
                ) { key in
                    let nowSelected = selectedKey?.id != key.id
                    selectedKey = nowSelected ? key : nil
                    // A toggle carries no spoken change on its own.
                    AccessibilityNotification.Announcement("\(key.label) \(nowSelected ? "selected" : "deselected")").post()
                }
            }
            .padding(20)
        }
        .navigationTitle("New Shortcut")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add") {
                    guard let shortcut = builtShortcut else { return }
                    store.rememberShortcut(shortcut)
                    store.layout[address] = .shortcut(shortcut)
                    onAssigned()
                }
                .fontWeight(.semibold)
                .disabled(builtShortcut == nil)
                // Otherwise VoiceOver says only "Add, dimmed".
                .accessibilityHint(builtShortcut == nil
                                   ? "Choose a key and at least one modifier to enable"
                                   : "Adds the shortcut and assigns it")
            }
        }
    }
    
    /// Drawn directly rather than through `KeyCapCell`, since a modifiers-only
    /// chord isn't yet a `PadCommand`.
    private var chordPreview: some View {
        VStack(spacing: 4) {
            KeyCapGlyph(glyph: .character(previewCapText))
                .foregroundStyle(.tint)
                .font(.system(size: 28))
                .frame(height: 34)
            if !previewCaption.isEmpty {
                Text(previewCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: 132, height: 76)
        .capSurface(usesGlass: true, isVisible: true, interactive: false, selected: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewSpoken)
        .accessibilityAddTraits(.updatesFrequently)
    }
    
    /// Mirrors `KeyPress.capText` for a chord that may have no key yet.
    private var previewCapText: String {
        orderedModifiers.map(\.symbol).joined() + (selectedKey?.chordCap ?? "")
    }
    
    /// Mirrors `KeyPress.captionText`.
    private var previewCaption: String {
        (orderedModifiers.map(\.shortName) + (selectedKey.map { [$0.label] } ?? []))
            .joined(separator: " + ")
    }
    
    private var previewSpoken: String {
        let mods = orderedModifiers.map(\.spokenName)
        if let selectedKey {
            return (mods + [selectedKey.label]).joined(separator: " ")
        }
        return mods.isEmpty ? "No key chosen yet"
        : mods.joined(separator: " ") + ", no key chosen yet"
    }
    
    private var modifierChips: some View {
        // Headed so the group the Add hint calls "modifiers" is named on screen
        // and reachable by the VoiceOver heading rotor.
        VStack(alignment: .leading, spacing: 10) {
            Text("Modifiers")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                ForEach(KeyModifier.allCases, id: \.self) { modifier in
                    let isOn = modifiers.contains(modifier)
                    Button {
                        if isOn {
                            modifiers.remove(modifier)
                        } else {
                            modifiers.insert(modifier)
                        }
                        AccessibilityNotification.Announcement("\(modifier.spokenName) \(isOn ? "off" : "on")").post()
                    } label: {
                        VStack(spacing: 2) {
                            Text(modifier.symbol)
                                .font(.system(size: 22, weight: .medium))
                            Text(modifier.shortName)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        // Two strokes: the 4pt one sits under the material and
                        // bleeds through as a tint, the 2pt one is the border.
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.tint, lineWidth: isOn ? 4 : 0)
                                .fill(AnyShapeStyle(.ultraThinMaterial))
                                .strokeBorder(.tint, lineWidth: isOn ? 2 : 0)
                        )
                        .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(modifier.spokenName)
                    .accessibilityHint("Modifier for the shortcut")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }
}

/// One key cap tile, captioned when the cap doesn't name itself, or a
/// plus-marked socket when empty.
private struct KeyCapCell: View {
    let command: PadCommand?
    var isSelected: Bool = false
    /// So the plus can't flash under a chip settling into this cell.
    var hidesPlus: Bool = false
    /// Glass only: makes the cap flex under the finger, reading as draggable.
    var isInteractive: Bool = false
    /// The picker's tiles opt out — a dense grid of glass shimmers odd/even.
    var usesGlass: Bool = true
    /// Empty sockets only; filled caps get theirs from the interactive glass.
    var isPressed: Bool = false
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.keyTilePressed) private var tilePressed
    
    private var pressed: Bool { isPressed || tilePressed }
    
    var body: some View {
        capContent
            .frame(maxWidth: .infinity, minHeight: 76)
        // A filled cap's socket is transparent; its glass surface is the fill.
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.black)
                        .opacity(command == nil ? 0.25 : 0)
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.tint)
                        .opacity(pressed ? 0.25 : 0)
                }
            )
        // On the content, not a pane in front of it, so the glyph rides on the
        // glass instead of being refracted through it.
            .capSurface(usesGlass: usesGlass, isVisible: command != nil || isSelected, interactive: isInteractive, selected: isSelected)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isSelected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
    }
    
    private var capContent: some View {
        VStack(spacing: 4) {
            Group {
                if let command {
                    KeyCapGlyph(glyph: command.glyph)
                        .foregroundStyle(.tint)
                } else if !hidesPlus {
                    Image(systemName: "plus")
                        .foregroundStyle(.tint.opacity(1))
                }
            }
            .font(.system(size: 28))
            .frame(height: 34)
            
            if let caption = command?.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

private extension EnvironmentValues {
    /// Lets the tile draw its own wash instead of the button style dimming it.
    @Entry var keyTilePressed: Bool = false
}

private extension View {
    /// Liquid Glass for the editor's caps, a material tile for the picker's.
    /// `isVisible` gates the glass so an empty, un-hovered socket shows only its
    /// recess.
    @ViewBuilder
    func capSurface(usesGlass: Bool, isVisible: Bool, interactive: Bool, selected: Bool) -> some View {
        if usesGlass, #available(iOS 26.0, *) {
            if isVisible {
                let tint: Color = selected ? .accentColor.opacity(0.15) : .clear
                glassEffect(
                    interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                    in: .rect(cornerRadius: 14)
                )
            } else {
                self
            }
        } else if usesGlass {
            background(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
        } else {
            // Two strokes: the 4pt one sits under the material and bleeds
            // through as a tint, the 2pt one is the border.
            background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, lineWidth: selected ? 4 : 0)
                    .fill(AnyShapeStyle(.ultraThinMaterial))
                    .strokeBorder(.tint, lineWidth: selected ? 2 : 0)
            )
        }
    }
    
    @ViewBuilder
    func glassRect() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        } else {
            background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        }
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

#Preview("Editor — from Preferences") {
    NavigationStack {
        KeyPadEditorContent(store: .preview(), showsEnablementHint: true)
    }
    .preferredColorScheme(.dark)
}

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
        KeyPickerView(store: .preview(.glyphSampler), address: CellAddress(zone: .pad, index: 4))
    }
    .preferredColorScheme(.dark)
}

#Preview("Shortcut builder") {
    NavigationStack {
        ShortcutBuilderView(store: .preview(), address: CellAddress(zone: .pad, index: 1)) {}
    }
    .preferredColorScheme(.dark)
}
