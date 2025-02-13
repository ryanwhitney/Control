import SwiftUI

struct BottomButtonPanel<Content: View>:  View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
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
    }
}
