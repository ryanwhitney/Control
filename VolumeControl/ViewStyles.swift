import SwiftUI

struct CircularButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .frame(width: 60, height: 60)
            .foregroundStyle(.tint)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .labelStyle(.iconOnly)
        }
}

