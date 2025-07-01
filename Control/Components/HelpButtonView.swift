import SwiftUI

struct HelpButtonView: View {
    let hasConnections: Bool
    let onHelp: () -> Void
    
    var body: some View {
        VStack {
            Spacer()
            if hasConnections {
                Button {
                    onHelp()
                } label: {
                    Label("Why isn't my device showing?", systemImage: "questionmark.circle.fill")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    onHelp()
                } label: {
                    Label("Why isn't my device showing?", systemImage: "questionmark.circle.fill")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.thickMaterial)
                        .cornerRadius(12)
                        .tint(.accentColor)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, hasConnections ? 20 : 8)
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