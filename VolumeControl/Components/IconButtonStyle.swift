import SwiftUI
import UIKit


struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .font(.system(size: 36))
            .fontWeight(.regular)
            .frame(width: 60, height: 60)
            .foregroundStyle(.tint)
            .labelStyle(.iconOnly)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}


struct IconButtonStyle_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 16) {
            Button {
                print("test")
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(IconButtonStyle())
            Button {
                print("test")
                } label: {
                    Image(systemName: "5.arrow.trianglehead.counterclockwise")
                }
                .buttonStyle(IconButtonStyle())

            Button {
                print("test")
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(IconButtonStyle())

            Button {
                print("test")
                } label: {
                    Image(systemName: "5.arrow.trianglehead.clockwise")
                }
                .buttonStyle(IconButtonStyle())

            Button {
                print("test")
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}

