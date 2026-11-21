import SwiftUI
import UIKit

/// An invisible first responder that raises the phone's keyboard and reports
/// each change as the `TypingEdit`s that make it on the Mac. A `UITextInput`
/// over a `TypingDocument` rather than a hidden text field: the keyboard gets
/// text to compose against and to move through with the space-bar trackpad,
/// while every committed change goes straight out instead of sitting in a
/// field of its own.
struct SoftKeyboardInput: UIViewRepresentable {
    @Binding var isActive: Bool
    /// Bumped when something other than the keyboard moved the Mac's caret,
    /// such as a pad key, so the copy of what was typed no longer lines up.
    var contextVersion = 0
    let onEdits: ([TypingEdit]) -> Void

    func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onEdits = onEdits
        view.onResign = {
            // Off the update pass: resigning can happen during one.
            Task { @MainActor in
                if isActive { isActive = false }
            }
        }
        if view.contextVersion != contextVersion {
            view.contextVersion = contextVersion
            view.resetDocument()
        }
        if isActive, !view.isFirstResponder {
            // Not until it's in a window, or becoming first responder fails.
            Task { @MainActor in
                if view.window != nil { view.becomeFirstResponder() }
            }
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class KeyInputView: UIView, UITextInput {
        var onEdits: (([TypingEdit]) -> Void)?
        var onResign: (() -> Void)?
        var contextVersion = 0
        private let echo = TypingEcho()
        private var document = TypingDocument()

        /// Layout for the keyboard's geometry questions: one fixed-width slot
        /// per character on a single line. Nothing is drawn; the width sets
        /// how far the space-bar trackpad drags per character.
        private static let characterWidth: CGFloat = 9
        private static let lineHeight: CGFloat = 20

        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(inputModeDidChange),
                name: UITextInputMode.currentInputModeDidChangeNotification,
                object: nil
            )
        }

        required init?(coder: NSCoder) {
            fatalError("Not built from a storyboard")
        }

        override var canBecomeFirstResponder: Bool { true }

        /// Dictation shows as its own input mode. Also checked at each edit,
        /// so a missed change notification can't leave typing held.
        private var isDictating: Bool {
            textInputMode?.primaryLanguage == "dictation"
        }

        /// Holds dictation on the phone until it ends, then sends the result
        /// once, instead of every revision it makes along the way.
        private func updateDictationHold() {
            if isDictating {
                document.beginHolding()
            } else if document.isHolding {
                send(document.endHolding())
            }
        }

        @objc private func inputModeDidChange() {
            guard isFirstResponder else { return }
            updateDictationHold()
        }

        private func send(_ edits: [TypingEdit]) {
            echo.setComposing(document.isHolding ? document.heldInsertion : document.markedText)
            guard !edits.isEmpty else { return }
            echo.apply(edits)
            onEdits?(edits)
        }

        /// Starts a fresh copy, committing any composition first. Notifies the
        /// keyboard, which otherwise keeps working from the old text.
        func resetDocument() {
            let commit = document.commitMarked() + document.endHolding()
            inputDelegate?.selectionWillChange(self)
            inputDelegate?.textWillChange(self)
            document = TypingDocument()
            inputDelegate?.textDidChange(self)
            inputDelegate?.selectionDidChange(self)
            send(commit)
        }

        @discardableResult
        override func resignFirstResponder() -> Bool {
            send(document.commitMarked() + document.endHolding())
            let resigned = super.resignFirstResponder()
            if resigned {
                document = TypingDocument()
                echo.clear()
                onResign?()
            }
            return resigned
        }

        // MARK: UIKeyInput

        /// Always true, so delete keeps firing past the start of the copy: the
        /// text it removes is on the Mac, not here.
        var hasText: Bool { true }

        func insertText(_ text: String) {
            updateDictationHold()
            send(document.insert(text))
            // Return may submit, and Tab moves focus, so the Mac's caret is
            // somewhere this copy can't follow. After this call returns, so
            // the keyboard isn't told mid-edit.
            if text.contains(where: { $0.isNewline || $0 == "\t" }) {
                DispatchQueue.main.async { [weak self] in self?.resetDocument() }
            }
        }

        func deleteBackward() {
            updateDictationHold()
            send(document.deleteBackward())
        }

        // MARK: UITextInput — text and selection

        weak var inputDelegate: UITextInputDelegate?
        lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
        var markedTextStyle: [NSAttributedString.Key: Any]?

        func text(in range: UITextRange) -> String? {
            guard let range = range as? DocumentRange else { return nil }
            return document.substring(range.nsRange)
        }

        func replace(_ range: UITextRange, withText text: String) {
            guard let range = range as? DocumentRange else { return }
            updateDictationHold()
            send(document.replace(range.nsRange, with: text))
        }

        var selectedTextRange: UITextRange? {
            get { DocumentRange(document.selection) }
            set {
                guard let range = newValue as? DocumentRange else { return }
                updateDictationHold()
                send(document.select(range.nsRange))
            }
        }

        var markedTextRange: UITextRange? {
            document.markedRange.map(DocumentRange.init)
        }

        func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            updateDictationHold()
            send(document.setMarked(markedText ?? "", selectedRange: selectedRange))
        }

        func unmarkText() {
            updateDictationHold()
            send(document.commitMarked())
        }

        // MARK: UITextInput — positions

        var beginningOfDocument: UITextPosition { DocumentPosition(0) }
        var endOfDocument: UITextPosition { DocumentPosition(document.length) }

        func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
            guard let from = fromPosition as? DocumentPosition, let to = toPosition as? DocumentPosition else { return nil }
            return DocumentRange(from: min(from.offset, to.offset), to: max(from.offset, to.offset))
        }

        func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
            guard let position = position as? DocumentPosition else { return nil }
            let target = position.offset + offset
            return (0...document.length).contains(target) ? DocumentPosition(target) : nil
        }

        func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
            switch direction {
            case .left, .up: return self.position(from: position, offset: -offset)
            default: return self.position(from: position, offset: offset)
            }
        }

        func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
            guard let a = position as? DocumentPosition, let b = other as? DocumentPosition else { return .orderedSame }
            return a.offset < b.offset ? .orderedAscending : (a.offset > b.offset ? .orderedDescending : .orderedSame)
        }

        func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
            guard let a = from as? DocumentPosition, let b = toPosition as? DocumentPosition else { return 0 }
            return b.offset - a.offset
        }

        func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
            switch direction {
            case .left, .up: return range.start
            default: return range.end
            }
        }

        func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
            switch direction {
            case .left, .up: return textRange(from: beginningOfDocument, to: position)
            default: return textRange(from: position, to: endOfDocument)
            }
        }

        func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
            .natural
        }

        func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

        // MARK: UITextInput — geometry

        func firstRect(for range: UITextRange) -> CGRect {
            let start = caretRect(for: range.start)
            let end = caretRect(for: range.end)
            return CGRect(x: start.minX, y: 0, width: max(end.minX - start.minX, 0), height: Self.lineHeight)
        }

        func caretRect(for position: UITextPosition) -> CGRect {
            let offset = (position as? DocumentPosition)?.offset ?? 0
            let x = CGFloat(document.characterIndex(of: offset)) * Self.characterWidth
            return CGRect(x: x, y: 0, width: 2, height: Self.lineHeight)
        }

        func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

        func closestPosition(to point: CGPoint) -> UITextPosition? {
            let index = Int((point.x / Self.characterWidth).rounded())
            return DocumentPosition(document.offset(ofCharacterIndex: index))
        }

        func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
            guard let range = range as? DocumentRange,
                  let position = closestPosition(to: point) as? DocumentPosition else { return nil }
            return DocumentPosition(min(max(position.offset, range.nsRange.location), NSMaxRange(range.nsRange)))
        }

        func characterRange(at point: CGPoint) -> UITextRange? {
            guard let position = closestPosition(to: point) as? DocumentPosition else { return nil }
            let end = document.offset(ofCharacterIndex: document.characterIndex(of: position.offset) + 1)
            return DocumentRange(from: position.offset, to: end)
        }

        // MARK: Space-bar trackpad

        /// Where the drag began, so each update moves by its distance from
        /// there rather than accumulating rounding.
        private var floatingCursorStart: (point: CGPoint, characterIndex: Int)?

        func beginFloatingCursor(at point: CGPoint) {
            floatingCursorStart = (point, document.characterIndex(of: document.selection.location))
        }

        /// Each step becomes an arrow press on the Mac, through `select`.
        func updateFloatingCursor(at point: CGPoint) {
            guard let start = floatingCursorStart else { return }
            let steps = Int(((point.x - start.point.x) / Self.characterWidth).rounded())
            let offset = document.offset(ofCharacterIndex: start.characterIndex + steps)
            guard offset != document.selection.location || document.selection.length > 0 else { return }
            inputDelegate?.selectionWillChange(self)
            send(document.select(NSRange(location: offset, length: 0)))
            inputDelegate?.selectionDidChange(self)
        }

        func endFloatingCursor() {
            floatingCursorStart = nil
        }

        // MARK: Traits

        // Off: the keyboard sees only what was typed here, not the Mac's text,
        // so anything that edits by context would guess wrong.
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        var inlinePredictionType: UITextInlinePredictionType = .no
        var keyboardType: UIKeyboardType = .default
        var returnKeyType: UIReturnKeyType = .default

        /// iPhone keyboards have no dismiss key, and the toggle cap may sit
        /// under the keyboard.
        override var inputAccessoryView: UIView? { accessoryHost.view }

        private lazy var accessoryHost: UIHostingController<SoftKeyboardAccessory> = {
            let host = UIHostingController(rootView: SoftKeyboardAccessory(echo: echo) { [weak self] in
                self?.resignFirstResponder()
            })
            // The keyboard positions the bar; insets of its own would pad it twice.
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 0, y: 0, width: 320, height: SoftKeyboardAccessory.height)
            host.view.autoresizingMask = [.flexibleWidth]
            return host
        }()
    }
}

private final class DocumentPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }
}

private final class DocumentRange: UITextRange {
    let nsRange: NSRange

    init(_ nsRange: NSRange) {
        self.nsRange = nsRange
    }

    convenience init(from: Int, to: Int) {
        self.init(NSRange(location: from, length: to - from))
    }

    override var start: UITextPosition { DocumentPosition(nsRange.location) }
    override var end: UITextPosition { DocumentPosition(NSMaxRange(nsRange)) }
    override var isEmpty: Bool { nsRange.length == 0 }
}

/// What was just typed, since the Mac's own field is out of view. It can only
/// echo the keys sent, not the Mac's text, so it fades soon after typing stops
/// rather than posing as the field's contents.
@MainActor
final class TypingEcho: ObservableObject {
    enum Token: Equatable {
        case character(Character)
        /// A key with no character of its own: return, tab, or a delete with
        /// nothing here to remove. Drawn with the key's own pad icon.
        case mark(RemoteKey)
    }

    @Published private(set) var tokens: [Token] = []
    @Published private(set) var isShowing = false

    /// Long enough to glance at, short enough not to linger as stale state.
    private static let holdDuration: Duration = .seconds(1.8)
    /// The bar shows the tail; older tokens can't be seen anyway.
    private static let maxTokens = 80

    private var fadeTask: Task<Void, Never>?

    /// In-progress composition (pinyin, kana), shown after the tokens. It
    /// isn't on the Mac yet, so it holds the echo up instead of fading.
    @Published private(set) var composing = ""

    func apply(_ edits: [TypingEdit]) {
        for edit in edits {
            switch edit {
            case .text(let text):
                record(text)
            case .deleteBackward(let count):
                for _ in 0..<count {
                    // Removes what it can see; otherwise says a delete went out.
                    if case .character = tokens.last {
                        tokens.removeLast()
                    } else {
                        tokens.append(.mark(.delete))
                    }
                }
            case .moveLeft, .moveRight:
                // The caret left the end, so the tail shown no longer ends
                // where typing lands.
                tokens = []
            }
        }
        if tokens.count > Self.maxTokens {
            tokens.removeFirst(tokens.count - Self.maxTokens)
        }
        refresh()
    }

    func setComposing(_ text: String) {
        guard text != composing else { return }
        composing = text
        refresh()
    }

    private func record(_ text: String) {
        for character in text {
            if character.isNewline {
                tokens.append(.mark(.return))
            } else if character == "\t" {
                tokens.append(.mark(.tab))
            } else if character.unicodeScalars.contains(where: { $0.value >= 0x20 && !(0x7F..<0xA0).contains($0.value) }) {
                // Matches what `textStatements` drops.
                tokens.append(.character(character))
            }
        }
    }

    private func refresh() {
        isShowing = !tokens.isEmpty || !composing.isEmpty
        if composing.isEmpty {
            scheduleFade()
        } else {
            fadeTask?.cancel()
        }
    }

    func clear() {
        fadeTask?.cancel()
        tokens = []
        composing = ""
        isShowing = false
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled, let self else { return }
            isShowing = false
            // Cleared after the fade, so the text doesn't vanish mid-animation
            // and the next burst starts empty.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            tokens = []
        }
    }
}

/// Floats above the keyboard: the typing echo, and the hide button iPhone
/// keyboards lack.
struct SoftKeyboardAccessory: View {
    /// Lifts the bar off the keyboard's top edge.
    static let keyboardGap: CGFloat = 24
    static let height: CGFloat = 44 + keyboardGap

    @ObservedObject var echo: TypingEcho
    let onHide: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            echoBubble
            Spacer(minLength: 0)
            Button(action: onHide) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .glassPillButtonStyle()
            .accessibilityLabel("Hide Keyboard")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height, alignment: .top)
        .themeTint(UserPreferences.shared.tintColorValue)
    }

    /// The tail of what was typed, so the latest key is always in view.
    private var echoBubble: some View {
        echoText
            .font(.body)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassCapsule()
            .opacity(echo.isShowing ? 1 : 0)
            .scaleEffect(echo.isShowing || reduceMotion ? 1 : 0.96, anchor: .leading)
            .animation(.easeOut(duration: echo.isShowing ? 0.12 : 0.4), value: echo.isShowing)
            // VoiceOver already speaks each key as it's typed.
            .accessibilityHidden(true)
    }

    private var echoText: Text {
        let typed = echo.tokens.reduce(Text("")) { text, token in
            switch token {
            case .character(let character):
                return text + Text(String(character))
            case .mark(let key):
                // A symbol, not text: ↩ and friends render as emoji on iOS.
                guard case .symbol(let name) = key.glyph else { return text + Text(key.label) }
                return text + Text(Image(systemName: name)).foregroundStyle(.tint)
            }
        }
        // Underlined, as composing text is in any iOS field.
        return typed + Text(echo.composing).underline()
    }
}

private extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: .capsule)
        }
    }
}

#Preview("Keyboard accessory") {
    let echo = TypingEcho()
    return VStack {
        Spacer()
        SoftKeyboardAccessory(echo: echo) {}
            .onAppear {
                echo.apply([.text("hello wor"), .deleteBackward(1), .text("rld\n")])
                echo.setComposing("ni hao")
            }
    }
    .preferredColorScheme(.dark)
}
