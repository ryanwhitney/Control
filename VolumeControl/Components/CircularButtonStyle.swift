import SwiftUI
import UIKit

private struct ScreenBrightnessKey: EnvironmentKey {
    static let defaultValue: CGFloat = UIScreen.main.brightness
}

extension EnvironmentValues {
    var screenBrightness: CGFloat {
        get { self[ScreenBrightnessKey.self] }
        set { self[ScreenBrightnessKey.self] = newValue }
    }
}

struct CircularButtonStyle: ButtonStyle {
    @Environment(\.screenBrightness) private var brightness
    
    func makeBody(configuration: Configuration) -> some View {
        let isLowBrightness = brightness < 0.25
        
        configuration.label
            .padding(12)
            .frame(width: 60, height: 60)
            .foregroundStyle(isLowBrightness ? .black : .accentColor)
            .background(isLowBrightness ? .green : .primary.opacity(0.15))
            .clipShape(Circle())
            .labelStyle(.iconOnly)
    }
}

