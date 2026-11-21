import SwiftUI

/// Shown the first time the Keyboard key is tapped, before the keyboard rises:
/// where typing goes, and what typing blind into the Mac can't do.
struct SoftKeyboardIntroSheet: View {
    var body: some View {
        HelpSheet(
            title: "Heads up: your Mac may adjust what you type",
            subtitle: "Here's how this works:",
            mailSubject: "📱 Keyboard typing help/question",
            mailBody: "Let me know what’s happening above and I’ll get back to you as soon as possible.",
            // Four explained points: too long to open at `.medium`.
            detents: [.large]
        ) {
            Section {
                point(
                    "keyboard.macwindow",
                    title: "This keyboard sends exactly what you type.",
                    detail: "Just like an external keyboard."
                )
                point(
                    "textformat.abc",
                    title: "Your Mac may autocorrect words along the way.",
                    detail: "Depending on what app you're typing into."
                )
                point(
                    "text.bubble",
                    title: "Autocorrect changes won't be visible within Control.",
                    detail: "Instead, we'll show a preview bubble of what you've typed here."
                )
            }
        }
    }

    private func point(_ symbol: String, title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .bold()
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

#Preview("SoftKeyboardIntroSheet") {
    Color.clear.sheet(isPresented: .constant(true)) {
        SoftKeyboardIntroSheet()
    }
}

#Preview("Inline") {
     SoftKeyboardIntroSheet()
 }
