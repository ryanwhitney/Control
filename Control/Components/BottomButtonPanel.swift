import SwiftUI

struct BottomButtonPanel<Content: View>:  View {
    let content: () -> Content
    /// Reports the panel's rendered height so the scroll content it floats over
    /// can reserve matching bottom clearance — measured, since Dynamic Type grows
    /// the buttons past any fixed guess.
    var height: Binding<CGFloat>?

    init(height: Binding<CGFloat>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.height = height
        self.content = content
    }

    var body: some View {
        VStack(spacing:0){
            content()
        }
        .padding(.top, 20)
        .background(
            LinearGradient(colors: [.clear, .black, .black, .black], startPoint: .top, endPoint: .bottom)
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            height?.wrappedValue = newValue
        }
    }
}
