//
//  GlassEffectIfAvailable.swift
//  Control
//

import SwiftUI

extension View {
    /// Uses the Liquid Glass button style on iOS 26+, falling back to the
    /// provided style on earlier versions.
    @ViewBuilder
    func glassButtonStyleIfAvailable<Fallback: PrimitiveButtonStyle>(
        fallback: Fallback
    ) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(fallback)
        }
    }

    /// Applies a background + corner radius only on pre-iOS 26 systems, where
    /// the Liquid Glass button style isn't available to provide its own surface.
    @ViewBuilder
    func legacyButtonBackground<Background: ShapeStyle>(
        _ background: Background,
        cornerRadius: CGFloat
    ) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self
                .background(background)
                .cornerRadius(cornerRadius)
        }
    }
}
