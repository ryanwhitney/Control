import SwiftUI
import UIKit

struct IconButtonStyle: ButtonStyle {
    @State private var bounceCount = 0
    @State private var isAnimating = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .font(.system(size: 36))
            .fontWeight(.regular)
            .frame(width: 60, height: 60)
            .foregroundStyle(.tint)
            .labelStyle(.iconOnly)
            .opacity((configuration.isPressed || isAnimating) ? 0.6 : 1.0)
            .symbolEffect(.bounce.down.wholeSymbol, options: .speed(3.0), value: bounceCount)
            .animation(.easeInOut(duration: 0.05), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.05), value: isAnimating)
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        bounceCount += 1
                        isAnimating = true
                        Task {
                            // End opacity fade before bounce completes
                            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
                            await MainActor.run {
                                isAnimating = false
                            }
                        }
                    }
            )
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
