import SwiftUI
import MultiBlur

struct WhatsNewView: View {
    @StateObject private var preferences = UserPreferences.shared
    let onDismiss: () -> Void

    private var newFeatures: [WhatsNewFeature] {
        let symbolText = Text("Update apps directly from the control screen ") +
        Text.withSymbolPrefixes(
            symbols: [Text.InlineSymbol(name: "ellipsis.circle.fill", accessibilityLabel: "three-dot")],
            text: "menu."
        )

        return [
            WhatsNewFeature(
                icon: "rectangle.portrait.on.rectangle.portrait.angled.fill",
                iconColor: .blue,
                title: "Choose Apps Anytime",
                description: symbolText,
            ),

            WhatsNewFeature(
                icon: "flask.fill",
                iconColor: .indigo,
                title: "Experimental App Controls",
                description: Text("Controls for Safari can now be enabled in Preferences."),
            ),
            WhatsNewFeature(
                icon: "camera.macro",
                iconColor: .green,
                title: "And other improvements…",
                description: Text("Better connectivity, bug fixes, button feedback, visual polish,  landscape layouts, and more."),
            )
        ]
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // Scrollable Content
                ScrollView {
                    VStack(spacing: 16) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 36))
                                .foregroundStyle(.tint)
                                .padding(.top, 20)
                                .multiblur([(10,0.25), (50,0.35)])
                            VStack(spacing:6){
                                Text("What's New")
                                    .font(.title)
                                    .fontWeight(.bold)
                                Text("Control now provides…more control")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top)
                        .padding(.bottom, 6)

                        // Features
                        VStack(spacing: 16) {
                            ForEach(newFeatures) { feature in
                                FeatureCard(feature: feature)
                            }
                            VStack(spacing: 4){
                                Text("These changes are powered by your feedback.")
                                Text("Thanks for using Control! 🙂")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                            Text("VERSION 1.1")
                                .font(.footnote)
                                .tracking(1)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal)
                    }
                }
                .scrollContentBackground(.hidden)

                // Fixed Button at Bottom
                VStack{
                    Spacer()
                    BottomButtonPanel{
                        Button {
                            preferences.markWhatsNewAsSeen()
                            onDismiss()
                        } label: {
                            HStack {
                                Text("Continue")
                                    .font(.headline)
                                    .multiblur([(10,0.25), (50,0.35)])
                            }
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                        }
                        .cornerRadius(12)
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                        .padding(.horizontal)
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .presentationBackground(.black)
        .tint(preferences.tintColorValue)
    }
}

struct FeatureCard: View {
    let feature: WhatsNewFeature

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(feature.iconColor.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: feature.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(feature.iconColor)
                    .multiblur([(10,0.25), (50,0.35)])
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline)
                    .fontWeight(.semibold)

                feature.description
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .accessibilityElement(children: .combine)
    }
}

struct WhatsNewFeature: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let description: Text
}

#Preview {
    WhatsNewView(onDismiss: {})
}
