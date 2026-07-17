import SwiftUI
import UIKit

struct IconButtonStyle: ButtonStyle {
    // Fixed sizes on purpose: a five-button transport row at these sizes already
    // fills a small phone's width, so scaling with Dynamic Type clips the outer
    // buttons off screen. 60pt is comfortably above tap-target minimums. The
    // key pad passes smaller values in phone landscape, where four rows have
    // to fit — 44pt, still the tap-target floor.
    var width: CGFloat = 60
    var height: CGFloat = 60
    var fontSize: CGFloat = 36
    @State private var bounceCount = 0
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .font(.system(size: fontSize))
            .fontWeight(.regular)
            .frame(width: width, height: height)
            .foregroundStyle(.tint)
            .labelStyle(.iconOnly)
            .opacity((configuration.isPressed || isAnimating) ? 0.6 : 1.0)
            .symbolEffect(.bounce.down.wholeSymbol, options: .speed(3.0), value: bounceCount)
            // The built-in Reduce Motion switch for symbol effects; keeps the
            // opacity press feedback. (A conditional trigger value would fire a
            // spurious bounce when the setting itself toggles.)
            .symbolEffectsRemoved(reduceMotion)
            .animation(.easeInOut(duration: 0.05), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.05), value: isAnimating)
            // Drive the bounce/fade from the press state, NOT a simultaneousGesture:
            // attaching a TapGesture to the label swallows the Button's own action
            // inside a paged TabView, so taps never fire.
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
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
            }
    }
}



struct IconButtonStyle_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 16) {
            Button {
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(IconButtonStyle())
            Button {
            } label: {
                Image(systemName: "5.arrow.trianglehead.counterclockwise")
            }
            .buttonStyle(IconButtonStyle())
            
            Button {
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            
            Button {
            } label: {
                Image(systemName: "5.arrow.trianglehead.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            
            Button {
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}
