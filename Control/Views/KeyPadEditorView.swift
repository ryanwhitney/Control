import SwiftUI
import UIKit
import MultiBlur

/// The editor as the control screen's gear presents it: wrapped in its own
/// stack with a Done button — leading, since the content's More menu owns the
/// trailing slot. Preferences pushes `KeyPadEditorContent` directly instead —
/// a pushed page takes its chrome from the parent stack.
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
struct KeyPadEditorContent: View {
    /// Injectable so previews can edit a throwaway layout; defaults to the
    /// persisted store.
    @ObservedObject var store: KeyPadLayoutStore = .shared
    /// Preferences turns this on: reached from there (rather than from a live
    /// pad), the hint notes that the layout is shared — one arrangement serves
    /// every connection with Keyboard controls enabled. From the control
    /// screen's gear the user is already standing on such a pad, so it'd be noise.
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
        /// Set on release: the settle animation owns the overlay now, so late
        /// gesture events must not move it.
        var isSettling = false
    }
    
    private struct DisplacedCap {
        /// The cell whose cap is mid-flight (hidden in the grid while its
        /// overlay flies to the source cell).
        let address: CellAddress
        let command: PadCommand
    }
    
    /// Reduce Motion swaps the settle flights for instant commits: the drag
    /// itself is direct manipulation (the cap tracks the finger 1:1), but the
    /// autonomous flying-home/swap animations are exactly what the setting
    /// asks to avoid.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    /// Restores VoiceOver to the cell that was being edited when the picker
    /// pops; the cell's own label and value then speak the outcome ("M, pad
    /// row 2, column 1") — confirmation and position in one, with no
    /// announcement to get clipped by focus speech.
    @AccessibilityFocusState private var focusedCell: CellAddress?
    
    @State private var drag: DragState?
    @State private var displaced: DisplacedCap?
    @State private var liftedCenter: CGPoint = .zero
    @State private var displacedCenter: CGPoint = .zero
    @State private var liftedScale: CGFloat = 1
    @State private var liftedOpacity: Double = 1
    @State private var cellFrames: [CellAddress: CGRect] = [:]
    @State private var removeZoneFrame: CGRect = .zero
    /// The empty socket currently under a finger — drives its button-like press
    /// wash. `@GestureState`, so it clears itself the moment the touch ends.
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
                    // The zones are distinct sets; more than the in-grid
                    // gap has to separate them or they read as one 3×4.
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
            // Back from the picker: it's a sheet (not a push) so VoiceOver keeps
            // this screen's tree and restores focus to the cell that opened it; a
            // pushed screen's pop would reset focus to the top-left. This deferred
            // set is the backstop, timed past the dismissal animation.
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
                // Attached to the menu, not the screen: the dialog anchors to
                // what raised it — from the outer scroll view it presents
                // detached (and as a mis-anchored popover on iPad).
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
        // Sheet presentation only; inert when this page is pushed.
        .interactiveDismissDisabled(drag != nil)
    }
    
    // MARK: Grid
    
    /// A zone at its stored dimensions — like the live pad, the editor never
    /// assumes a shape, so data from a version with wider zones still renders.
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
        // A cap is "airborne" when the real thing is an overlay in flight rather
        // than sitting in this cell: the lift source, a mid-swap displaced cap, or
        // — once released — the target it's settling onto. Those render with no
        // glyph; whether the emptied socket shows its plus is `hidesPlus`'s call.
        let isSettling = drag?.isSettling ?? false
        let isSource = drag?.source == address
        let isDropTarget = drag?.target == .cell(address)
        let capIsAirborne = isSource
        || displaced?.address == address
        || (isDropTarget && isSettling)
        // Hide the socket's plus only while a chip is settling into this cell, so
        // it can't flash under the landing chip. A freshly lifted source (drag
        // underway, nothing landing yet) keeps its plus.
        let hidesPlus = isSettling && (
            isDropTarget || (isSource && (displaced != nil || drag?.target == nil))
        )
        // Tint marks the live drop target only; it clears the instant the cap
        // is released so the landing chip is the only glass in the cell.
        let isHovered = isDropTarget && !isSettling
        // Interactive glass reacts to touches at the compositing level, even
        // through a presented sheet — so drop the interactivity while the picker
        // is open, or pressing its caps lights up the editor caps beneath.
        return KeyCapCell(command: capIsAirborne ? nil : command, isSelected: isHovered, hidesPlus: hidesPlus, isInteractive: editingCell == nil, isPressed: pressedCell == address)
        // Explicit shape so taps and drop targeting work on empty cells,
        // whose transparent fill isn't hit-testable on its own.
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
        // Button-like press feedback for empty sockets (filled caps get it
        // from their interactive glass). A 0-distance drag just flags the
        // touch-down; it runs alongside the tap and lift without claiming
        // them, and only empty cells record it.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressedCell) { _, state, _ in
                        if command == nil { state = address }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(command?.label ?? "Empty space")
        // The grid is positional, so VoiceOver needs the coordinates
        // sighted users get from the layout.
            .accessibilityValue(store.layout.accessibilityPosition(of: address))
            .accessibilityHint("Chooses the key for this space")
        // Voice Control names, matching the live pad's ("Tap Up arrow").
            .accessibilityInputLabels(command?.inputLabels ?? ["Empty space"])
            .accessibilityAction {
                editingCell = address
            }
            .accessibilityActions {
                // One-step removal from the rotor/Switch Control menu — parity
                // with drag-to-remove, which assistive tech can't perform.
                if command != nil {
                    Button("Remove Key") {
                        store.layout[address] = nil
                        // Rotor actions give no feedback of their own, and
                        // focus stays put rather than re-reading the cell.
                        AccessibilityNotification.Announcement("Key removed").post()
                    }
                }
            }
            .accessibilityFocused($focusedCell, equals: address)
    }
    
    /// The caps in flight, drawn in the editor's coordinate space above the
    /// grid: the lifted cap under the finger, and — during a swap settle —
    /// the displaced cap flying to the vacated cell.
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
            // Transient drag chrome; never a focusable element.
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
    
    /// Notes that the pad layout is global: one arrangement serves every
    /// connection with Keyboard controls enabled, so an edit here changes them all.
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
    
    private func beginDrag(from address: CellAddress) {
        guard drag == nil,
              let command = store.layout[address],
              let frame = cellFrames[address] else { return }
        drag = DragState(source: address, command: command)
        liftedCenter = frame.center
        liftedOpacity = 1
        if reduceMotion {
            // Still lifted-looking (the scale is state, not motion) — just no
            // spring getting there.
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
        // Targeting follows the finger, not the cap's centre — standard drop
        // behaviour, and it keeps working when the grab point is off-centre.
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
            // The source cell is "nowhere": releasing there settles the cap
            // back rather than swapping with itself. Cross-zone drops are
            // deliberately just drops — no zone rules to explain.
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
            // Reduce Motion: no flight — commit in place and let the grid
            // redraw where everything already is.
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
                // Commit and clear in the same transaction: the grid takes
                // over exactly where the overlays stopped, so nothing jumps.
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
            settleBack()
        }
    }
    
    /// Floats the lifted cap back to its own cell — no valid target under the
    /// finger, or the drag was cancelled.
    private func settleBack() {
        guard var drag else { return }
        drag.isSettling = true
        self.drag = drag
        if reduceMotion {
            finishDrag()
            return
        }
        withAnimation(Self.settleSpring, completionCriteria: .logicallyComplete) {
            if let frame = cellFrames[drag.source] {
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
    /// Spoken coordinates for a cell — the zone name tells VoiceOver which
    /// grid it's in, since the two look alike to a swipe.
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

/// Chooses the key for one pad cell: the full unmodified keyboard, grouped
/// into sections and drawn as key caps. A sheet rather than a push — a pop's
/// screen-change resets VoiceOver focus to the top-left, while dismissing a
/// sheet returns it to the cell being edited. The medium detent keeps the
/// grid visible behind it. Selecting dismisses; Remove empties the cell.
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
                    // Nothing on screen says what selecting does, so the
                    // hint carries it — spoken after a pause, suppressible
                    // in VoiceOver settings.
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
                        // The app's theme tint colors toolbar items; removal
                        // must read as destructive regardless of theme.
                        .tint(.red)
                    }
                }
            }
            .navigationDestination(isPresented: $showingShortcutBuilder) {
                ShortcutBuilderView(store: store, address: address) {
                    // Assigned from the builder: the picker's job is done too,
                    // so the whole sheet goes, not just the pushed page.
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
        // Let the tapped key flip to its selected state before the sheet leaves;
        // dismissing in the same instant hides the confirmation and reads as a
        // no-op.
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            dismiss()
        }
    }
    
    // MARK: Shortcuts row
    
    /// Presets, then the user's own chords, then the "new" cap — above the plain
    /// keys.
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
        // Match by content, not full value: a hand-built chord is stored
        // name-less, so `==` against a same-chord preset (which carries a name)
        // would miss and leave nothing highlighted. contentID is the identity.
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
            // Presets and user creations alike can leave the row: a preset is
            // only hidden (rebuilding its chord restores it), a creation is
            // dropped. Cells keep their own copy, so a placed cap survives.
            // (Context menu items surface to VoiceOver as custom actions.)
            Button("Delete Shortcut", role: .destructive) {
                store.deleteShortcut(shortcut)
            }
        }
        .accessibilityLabel(shortcut.spokenText)
        .accessibilityHint("Assigns this shortcut to \(positionDescription)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    
    /// A glass "+ Add" tile — the shortcuts row's create action. Same rounded
    /// shape as the key tiles but Liquid Glass rather than material, so it reads
    /// as an action rather than another cap.
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

/// Press feedback for the picker's chooser tiles. The wash itself is drawn
/// inside the tile (`KeyCapCell`), matching the editor's empty-cell feedback;
/// this style just surfaces the pressed flag to it via the environment. No
/// dim/scale on the label — those read as sluggish on a tap-to-assign grid.
private struct PickerKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.keyTilePressed, configuration.isPressed)
    }
}

/// The sectioned key catalog as cap tiles, shared by the picker (tap =
/// assign) and the shortcut builder (tap = select the chord's key).
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
                    // Rotor heading navigation: ~70 keys is too many to
                    // swipe through without section jumps.
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
    /// Runs after Add so the presenter can dismiss the whole picker sheet —
    /// popping back alone would strand the user on a picker they're done with.
    let onAssigned: () -> Void
    
    /// ⌘ pre-armed: every shortcut needs a modifier and ⌘ is most of them.
    @State private var modifiers: Set<KeyModifier> = [.command]
    @State private var selectedKey: RemoteKey?
    
    private var builtShortcut: KeyShortcut? {
        guard let selectedKey, !modifiers.isEmpty else { return nil }
        return KeyShortcut(name: nil, presses: [KeyPress(key: selectedKey, modifiers: Array(modifiers))])
    }
    
    /// Modifiers in canonical ⌃⌥⇧⌘ order, for a stable preview and spoken label.
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
                    // Toggle, like the modifier chips: tapping the chosen key
                    // again clears it (which disables Add until one's re-picked).
                    let nowSelected = selectedKey?.id != key.id
                    selectedKey = nowSelected ? key : nil
                    // Toggles carry no spoken change on their own; confirm it.
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
                // Spell out why it's dimmed — otherwise VoiceOver just says
                // "Add, dimmed" with no path forward.
                .accessibilityHint(builtShortcut == nil
                                   ? "Choose a key and at least one modifier to enable"
                                   : "Adds the shortcut and assigns it")
            }
        }
    }
    
    /// The chord as assembled so far: the armed modifiers show at once (⌘) and
    /// the key joins when picked (⌘C). Display-only — the real cap is built on
    /// Add, which stays disabled until a key is chosen. Drawn directly rather
    /// than through `KeyCapCell` because a modifiers-only chord isn't yet a
    /// `PadCommand`.
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
    
    /// The cap glyph text, mirroring `KeyPress.capText`: modifier symbols, then
    /// the key's chord cap once one is chosen ("⌘", then "⌘C").
    private var previewCapText: String {
        orderedModifiers.map(\.symbol).joined() + (selectedKey?.chordCap ?? "")
    }
    
    /// The caption, mirroring `KeyPress.captionText` ("Cmd", then "Cmd + C").
    private var previewCaption: String {
        (orderedModifiers.map(\.shortName) + (selectedKey.map { [$0.label] } ?? []))
            .joined(separator: " + ")
    }
    
    /// The spoken form for the preview, naming what's chosen and flagging when a
    /// key is still needed.
    private var previewSpoken: String {
        let mods = orderedModifiers.map(\.spokenName)
        if let selectedKey {
            return (mods + [selectedKey.label]).joined(separator: " ")
        }
        return mods.isEmpty ? "No key chosen yet"
        : mods.joined(separator: " ") + ", no key chosen yet"
    }
    
    private var modifierChips: some View {
        // Headed like the key catalog's sections, so the group the Add hint calls
        // "modifiers" is named on screen and reachable by VoiceOver heading rotor.
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
                        // Toggles carry no spoken change on their own; confirm it.
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
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.tint, lineWidth: isOn ? 4 : 0)
                                .fill( AnyShapeStyle(.ultraThinMaterial))
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

/// One key cap tile: glyph centred, captioned beneath when the cap doesn't
/// name itself (an arrow glyph or a "⌘Z" chord; "A" does), a plus-marked
/// material socket when empty. `isSelected` highlights either the picker's
/// current command (a tint border on the material tile) or the editor cell a
/// drag is hovering (an accent tint on the glass).
private struct KeyCapCell: View {
    let command: PadCommand?
    var isSelected: Bool = false
    /// Suppresses the empty socket's plus — set while a dragged cap is settling
    /// into this cell, so the plus can't flash under the landing chip.
    var hidesPlus: Bool = false
    /// Adds `.interactive()` to the glass so a cap flexes and brightens under
    /// the finger — the editor caps use it as a "this is draggable" affordance.
    /// Only meaningful for glass caps.
    var isInteractive: Bool = false
    /// Editor caps are Liquid Glass; the picker's chooser tiles opt out (a dense
    /// grid of glass renders with an odd/even shimmer, and they're a selection
    /// list rather than the live pad — so they get a plain material tile).
    var usesGlass: Bool = true
    /// Touch-down feedback for an empty socket (filled caps get theirs from the
    /// interactive glass): washes the socket with a slight accent tint.
    var isPressed: Bool = false
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by `PickerKeyStyle` while a chooser tile is pressed; folded in with
    /// the editor's gesture-driven `isPressed` so both draw the same wash.
    @Environment(\.keyTilePressed) private var tilePressed
    
    private var pressed: Bool { isPressed || tilePressed }
    
    var body: some View {
        capContent
            .frame(maxWidth: .infinity, minHeight: 76)
        // Empty cells read as a faint material socket; a filled cap's socket
        // is transparent (its glass surface is the fill). While pressed — an
        // empty editor socket or any picker tile — a slight accent wash gives
        // button-like feedback (filled editor caps get theirs from the
        // interactive glass instead).
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
        // A filled cap always sits on glass; an empty socket takes it only
        // while it's the hover target. Applied to the content — not a pane
        // in front of it — so the glyph and caption ride on the glass
        // rather than being refracted through it.
            .capSurface(usesGlass: usesGlass, isVisible: command != nil || isSelected, interactive: isInteractive, selected: isSelected)
        // The press/selection washes ramp in quickly; Reduce Motion snaps.
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
                    // The plus invites a tap and marks an emptied cell — shown
                    // the moment a cap lifts. It's hidden only while a cap is
                    // settling in, so it can't flash under the landing chip.
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
    /// Set by `PickerKeyStyle` while a chooser tile is pressed, so the tile can
    /// draw its own accent wash (matching the editor's empty-cell feedback)
    /// rather than the button style dimming the whole label.
    @Entry var keyTilePressed: Bool = false
}

private extension View {
    /// The cap's surface, applied to the content so the glyph rides on it rather
    /// than being refracted through a pane in front. Glass caps (the editor pad)
    /// get Liquid Glass — plus `.interactive()` when tappable — tinted while a
    /// drag hovers. Non-glass caps (the picker's chooser tiles) get a material
    /// tile that gains a tint border when selected, since a dense grid of glass
    /// renders with an odd/even shimmer and the chooser is a selection list, not
    /// the live pad. Their press feedback comes from `PickerKeyStyle`. `isVisible`
    /// gates the glass so an empty, un-hovered editor socket shows only its recess.
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
            // Pre-iOS 26 fallback for glass caps: a plain tint fill.
            background(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
        } else {
            // Picker chooser tile: material fill, gaining a tint border when
            // selected — matching the modifier chips.
            background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, lineWidth: selected ? 4 : 0)
                    .fill(AnyShapeStyle(.ultraThinMaterial))
                    .strokeBorder(.tint, lineWidth: selected ? 2 : 0)
            )
        }
    }
    
    /// A rounded-rect Liquid Glass surface (interactive) on iOS 26; a material
    /// tile on earlier systems — for the shortcuts row's glass "Add" action.
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
