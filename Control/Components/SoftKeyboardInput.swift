import SwiftUI
import UIKit

/// An invisible first responder that raises the phone's keyboard and reports
/// each insertion, with deletes as `KeyboardApp.deleteBackward`. `UIKeyInput`
/// rather than a text field: there's no local text, every key goes straight to
/// the Mac, and a hidden field would fight that with its own editing.
struct SoftKeyboardInput: UIViewRepresentable {
    @Binding var isActive: Bool
    let onText: (String) -> Void

    func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onText = onText
        view.onResign = {
            // Off the update pass: resigning can happen during one.
            Task { @MainActor in
                if isActive { isActive = false }
            }
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

    final class KeyInputView: UIView, UIKeyInput {
        var onText: ((String) -> Void)?
        var onResign: (() -> Void)?
        private let echo = TypingEcho()

        override var canBecomeFirstResponder: Bool { true }

        /// Always true, so delete keeps firing however much has been typed:
        /// the text it removes is on the Mac, not here.
        var hasText: Bool { true }

        func insertText(_ text: String) {
            echo.record(text)
            onText?(text)
        }

        func deleteBackward() {
            echo.record(KeyboardApp.deleteBackward)
            onText?(KeyboardApp.deleteBackward)
        }

        @discardableResult
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned {
                echo.clear()
                onResign?()
            }
            return resigned
        }

        // The keyboard can't see the Mac's text, so anything that edits by
        // context would guess wrong — and replacements arrive as fresh typing.
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

    func record(_ input: String) {
        var previous: Unicode.Scalar?
        for scalar in input.unicodeScalars {
            defer { previous = scalar }
            switch scalar {
            case "\r":
                tokens.append(.mark(.return))
            case "\n":
                if previous != "\r" { tokens.append(.mark(.return)) }
            case "\t":
                tokens.append(.mark(.tab))
            case "\u{7F}":
                // Removes what it can see; otherwise says a delete went out.
                if case .character = tokens.last {
                    tokens.removeLast()
                } else {
                    tokens.append(.mark(.delete))
                }
            default:
                // Matches what `typingStatements` drops.
                guard scalar.value >= 0x20, !(0x7F..<0xA0).contains(scalar.value) else { continue }
                // Appended to the previous character when it combines with it
                // (an accent, a skin tone), so it echoes as one.
                if case .character(let last) = tokens.last {
                    let combined = String(last) + String(scalar)
                    if combined.count == 1 {
                        tokens[tokens.count - 1] = .character(Character(combined))
                        continue
                    }
                }
                tokens.append(.character(Character(scalar)))
            }
        }
        if tokens.count > Self.maxTokens {
            tokens.removeFirst(tokens.count - Self.maxTokens)
        }
        isShowing = !tokens.isEmpty
        scheduleFade()
    }

    func clear() {
        fadeTask?.cancel()
        tokens = []
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
    /// Bar plus the gap that lifts it off the keyboard.
    static let height: CGFloat = 60

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
        .padding(.bottom, 10)
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
        echo.tokens.reduce(Text("")) { text, token in
            switch token {
            case .character(let character):
                return text + Text(String(character))
            case .mark(let key):
                // A symbol, not text: ↩ and friends render as emoji on iOS.
                guard case .symbol(let name) = key.glyph else { return text + Text(key.label) }
                return text + Text(Image(systemName: name)).foregroundStyle(.tint)
            }
        }
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
            .onAppear { echo.record("hello wor\u{7F}rld\n") }
    }
    .preferredColorScheme(.dark)
}
