import SwiftUI

struct HelpButtonView: View {
    let hasConnections: Bool
    let onHelp: () -> Void

    var body: some View {
        VStack {
            Spacer()
            if hasConnections {
                HelpPromptButton(onHelp: onHelp)
            } else {
                Button {
                    onHelp()
                } label: {
                    Label("Why isn't my device showing?", systemImage: "questionmark.circle.fill")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .tint(.accentColor)
                        .foregroundStyle(.tint)
                        .legacyButtonBackground(.thickMaterial, cornerRadius: 12)
                }
                .glassButtonStyleIfAvailable(fallback: .bordered)
                .tint(.gray)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, hasConnections ? 20 : 8)
    }
}

/// The plain "why isn't my device showing?" button. Shared between the floating
/// overlay (short lists) and the inline list footer (lists tall enough to scroll).
struct HelpPromptButton: View {
    let onHelp: () -> Void

    var body: some View {
        Button {
            onHelp()
        } label: {
            Label("Why isn't my device showing?", systemImage: "questionmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

#Preview("No Connections") {
    ZStack {
        Color.gray.opacity(0.1)
        HelpButtonView(
            hasConnections: false,
            onHelp: {}
        )
    }
    .frame(height: 300)
}

#Preview("With Connections") {
    ZStack {
        Color.gray.opacity(0.1)
        HelpButtonView(
            hasConnections: true,
            onHelp: {}
        )
    }
    .frame(height: 300)
}
