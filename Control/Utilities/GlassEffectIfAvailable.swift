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
    
    @ViewBuilder
    func glassEffectOrFallback<Background: View>(
        @ViewBuilder background: () -> Background
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(.red.opacity(0.2)))
                
        } else {
            self.background(background())
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

    /// Chrome for the app's full-width pill buttons. Untinted = the auth/
    /// permissions/setup CTAs: neutral glass (iOS 26+) or gray bordered over
    /// material (earlier), with an accent label. Tinted = the preference-page
    /// and notice actions, which keep their own solid color: color-tinted
    /// glass (iOS 26+, the What's New treatment — a tinted interactive
    /// glassEffect layered on the glass button style) or the original tinted
    /// bordered pill (earlier). Pair with `glassPillLabel` inside the label
    /// so the text follows the tint and dims when disabled.
    @ViewBuilder
    func glassPillButtonStyle(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                // The system glass surface, tinted by a color capsule painted
                // *behind* it: the glass samples and refracts the capsule, so
                // it reads as tinted glass. One glass layer only — a tinted
                // glassEffect stacked on the glass button style is two glass
                // surfaces sampling each other, which shimmers while the page
                // scrolls under them.
                buttonStyle(.glass)
                    .background(Capsule().fill(tint.opacity(0.45)))
                    .tint(tint)
            } else {
                buttonStyle(.glass)
                    .tint(.accentColor)
            }
        } else if let tint {
            background(tint.opacity(0.025))
                .cornerRadius(.infinity)
                .buttonStyle(.bordered)
                .tint(tint)
        } else {
            background(.ultraThinMaterial)
                .cornerRadius(.infinity)
                .buttonStyle(.bordered)
                .tint(.gray)
        }
    }

    /// Label foreground for pill buttons. With a `tint` (the CTA pills, whose
    /// accent text differs from their gray chrome pre-26): that tint while
    /// enabled, secondary when disabled — a hard-coded label color never dims,
    /// which was the old black-button-on-empty-form look. Without a tint (the
    /// tinted glass pills): on iOS 26+ the label is left to the glass button
    /// style; pre-26 it follows the chrome tint with the same disabled
    /// treatment.
    func glassPillLabel(tint: Color? = nil) -> some View {
        modifier(GlassPillLabel(tint: tint))
    }
}

private struct GlassPillLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), tint == nil {
            content
        } else {
            content
                .tint(tint)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}
