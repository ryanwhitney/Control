import SwiftUI

extension Button {
    func styledButton() -> some View {
        self.padding(12)
            .frame(width: 60, height: 60)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .labelStyle(.iconOnly)
    }
} 