import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preferences = UserPreferences.shared
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    PreferencesRow(
                        destination: ThemePreferenceView(),
                        iconName: "paintbrush.fill",
                        title: "Theme",
                        color: .green
                    )
                    PreferencesRow(
                        destination: ExperimentalPlatformsView(),
                        iconName: "flask.fill",
                        title: "Experimental App Controls",
                        color: .indigo
                    )
                }
                Section {
                    Picker("Connection Method", selection: $preferences.connectionMethod) {
                        ForEach(ConnectionMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: preferences.connectionMethod) { _, _ in
                        // An explicit choice supersedes any transient auto-fallback.
                        SSHConnectionManager.shared.userDidChooseConnectionMethod()
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("“Fast” keeps one connection open. “Compatibility” runs each command on its own connection — try it if Fast has trouble connecting to or controlling your Mac. Takes effect the next time you connect.")
                }
                Section {
                    PreferencesRow(
                        destination: FeedbackPreferenceView(),
                        iconName: "paperplane.fill",
                        title: "Send Feedback",
                        color: .blue
                    )
                    PreferencesRow(
                        destination: SupportPreferenceView(),
                        iconName: "questionmark.diamond.fill",
                        title: "Support",
                        color: .orange
                    )
                }
            }
            .padding(.top, 30)
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
    let iconName: String
    let title: String
    let color: Color

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack {
                Image(systemName: iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .padding(4)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(title)
            }
        }
    }
}



#Preview {
    PreferencesView()
} 
