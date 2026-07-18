import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preferences = UserPreferences.shared
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Control Mode", selection: $preferences.connectionMethod) {
                        ForEach(ConnectionMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: preferences.connectionMethod) { _, _ in
                        // An explicit choice supersedes any transient auto-fallback.
                        SSHConnectionManager.shared.userDidChooseConnectionMethod()
                    }
                } footer: {
                    Text("Configures how commands are sent to your Mac. Fast may be less stable. If controls become less reliable, try Compatibility.")
                }
                Section {
                    PreferencesRow(
                        destination: ThemePreferenceView(),
                        iconName: "paintbrush.fill",
                        title: "Theme",
                        color: .green
                    )
                    PreferencesRow(
                        destination: KeyPadEditorContent(showsEnablementHint: true),
                        customIconName: "custom.arrowtriangles.up.right.down.left",
                        title: "Customize Keyboard Controls",
                        color: .black.opacity(0.35)
                    )
                    PreferencesRow(
                        destination: ExperimentalPlatformsView(),
                        iconName: "flask.fill",
                        title: "Experimental App Controls",
                        color: .indigo
                    )
                }
                Section {
                    PreferencesRow(
                        destination: SupportPreferenceView(),
                        iconName: "questionmark.diamond.fill",
                        title: "Support",
                        color: .orange
                    )
                    PreferencesRow(
                        destination: FeedbackPreferenceView(),
                        iconName: "paperplane.fill",
                        title: "Send Feedback",
                        color: .blue
                    )
                }
                
            }
            .contentMargins(.top, 30, for: .scrollContent)
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .tint(preferences.tintColorValue)
    }
}



struct PreferencesRow<Destination: View>: View {
    let destination: Destination
    let icon: Image
    let title: String
    let color: Color
    /// Per-symbol stroke weight; nil leaves the symbol's natural weight.
    /// Works for custom catalog symbols too — the template's
    /// Ultralight/Regular/Black sources interpolate the rest.
    let weight: Font.Weight?

    /// A system SF Symbol.
    init(destination: Destination, iconName: String, title: String, color: Color, weight: Font.Weight? = nil) {
        self.destination = destination
        self.icon = Image(systemName: iconName)
        self.title = title
        self.color = color
        self.weight = weight
    }

    /// A custom symbol from the asset catalog (an SF Symbols app export
    /// dropped into Assets.xcassets) — those load by asset name, not
    /// `systemName`.
    init(destination: Destination, customIconName: String, title: String, color: Color, weight: Font.Weight? = nil) {
        self.destination = destination
        self.icon = Image(customIconName)
        self.title = title
        self.color = color
        self.weight = weight
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack {
                icon
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(weight)
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .padding(4)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(title)
            }
        }
    }
}



#Preview {
    PreferencesView()
} 
