import SwiftUI
import UIKit


struct CircularButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {

        configuration.label
            .padding(12)
            .fontWeight(.medium)
            .frame(width: 60, height: 60)
            .foregroundStyle(Color.accentColor)
            .background( Color.accentColor.opacity(0.15))
            .clipShape(Circle())
            .labelStyle(.iconOnly)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}


struct CircularButtonStyle_Previews: PreviewProvider {
    static var previews: some View {

        HStack(spacing: 20) {
            Button {
                print("test")
            } label: {
                    Text("-5")
                }
                .buttonStyle(CircularButtonStyle())

            Button {
                print("test")
                } label: {
                    Text("-1")
                }
                .buttonStyle(CircularButtonStyle())

            Button {
                print("test")
                } label: {
                    Text("+1")
                }
                .buttonStyle(CircularButtonStyle())

            Button {
                print("test")
                } label: {
                    Text("+5")
                }
                .buttonStyle(CircularButtonStyle())
        }
    }
}

