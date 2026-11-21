import SwiftUI
import MultiBlur

struct WhatsNewView: View {
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var bottomPanelHeight: CGFloat = 0
    let onDismiss: () -> Void

    /// The sheet only floats as a centered, bordered card in regular-width
    /// presentations (e.g. iPad). On iPhone it's a full-screen sheet, where a
    /// border would look out of place.
    private var isFloatingDialog: Bool {
        horizontalSizeClass == .regular
    }

    private let newFeatures = [
        WhatsNewFeature(
            icon: "hare.fill",
            title: "Take Control Faster",
            description: Text("Set “Open on launch” by swiping to edit a recent connection, or long-press the app icon to open directly to controls.")
        ),
        WhatsNewFeature(
            icon: "keyboard",
            title: "Use Your Full Device Keyboard",
            description: Text("Adds a new key control that lets you open this device’s keyboard.")
            
            
        ),
        WhatsNewFeature(
            icon: "square.grid.3x3.fill",
            title: "Pick Your Own Keyboard Icons",
            description: Text("Give custom keyboard shortcuts their own icons.")
        ),
    ]

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // Scrollable Content
                ScrollView {
                    VStack(spacing: 16) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "app.gift.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.tint)
                                .padding(.top, 20)
                                .multiblur([(10, 0.65), (100, 0.5)])
                                .accessibilityHidden(true)
                            VStack(spacing: 6) {
                                Text("What’s New")
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .accessibilityAddTraits(.isHeader)
                                Text("Do more, more quickly.")
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
                            VStack(spacing: 10){
                                (Text("Customize keys under ")
                                 + Text(Image(systemName: "gearshape.fill")).foregroundStyle(.tint)
                                 + Text(" on the Keyboard control screen, or in Preferences."))
                                // Names the gear as VoiceOver announces the button itself.
                                .accessibilityLabel("Customize keys with the Customize Keyboard Controls button on the Keyboard control screen, or in Preferences.")

                                (Text("Thanks to all who provided feedback. ") + Text(Image(systemName: "heart.fill").symbolRenderingMode(.multicolor)))
                                    .accessibilityLabel("Thanks to all who provided feedback.")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                            Text("VERSION 2.2.0")
                                .font(.footnote)
                                .tracking(1)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal)
                    }
                    // Clearance for the floating Continue panel, measured live
                    // so it stays right when Dynamic Type grows the button.
                    .padding(.bottom, bottomPanelHeight + 12)
                }
                .scrollContentBackground(.hidden)

                // Fixed Button at Bottom
                VStack {
                    Spacer()
                    BottomButtonPanel(height: $bottomPanelHeight) {
                        if #available(iOS 26.0, *) {
                            Button {
                                preferences.markWhatsNewAsSeen()
                                onDismiss()
                            } label: {
                                continueLabel
                            }
                            .buttonStyle(.glass)
                            .glassEffect(.regular.tint(.green).interactive())
                            .tint(.green)
                            .padding(.horizontal)
                            .padding(.vertical, 16)
                        } else {
                            Button {
                                preferences.markWhatsNewAsSeen()
                                onDismiss()
                            } label: {
                                continueLabel
                            }
                            .cornerRadius(12)
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                            .padding(.horizontal)
                            .padding(.vertical, 16)
                        }
                    }
                }
            }
            .background(Color(.black))
            .border(Color(.gray).opacity(isFloatingDialog ? 0.5 : 0), width: 1)
            .navigationBarHidden(true)
        }
        .presentationBackground(.black)
        .themeTint(preferences.tintColorValue)
    }

    private var continueLabel: some View {
        HStack {
            Text("Continue")
                .font(.headline)
                .multiblur([(10, 0.25), (50, 0.35)])
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .fontWeight(.bold)
    }
}

struct FeatureCard: View {
    let feature: WhatsNewFeature

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: feature.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tint)
                    .multiblur([(10, 0.25), (50, 0.35)])
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline)
                    .fontWeight(.semibold)

                feature.description
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
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
    let title: String
    let description: Text
}

#Preview {
    WhatsNewView(onDismiss: {})
}
