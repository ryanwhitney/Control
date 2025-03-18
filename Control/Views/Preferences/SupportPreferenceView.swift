import SwiftUI
import MultiBlur

struct SupportPreferenceView: View {
    @State private var showMailComposer = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing:16){
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8){
                    Text("Found an issue?")
                        .font(.headline)
                    Text("This app includes zero analytics or tracking. If you run into any bug or issues, please let me know and I'll do my best to fix it.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8){
                    Text("App or feature requests")
                        .font(.headline)
                    Text("Control comes with support for few popular Mac apps, but more can be added. Feel free to request additional apps or features.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    showMailComposer = true
                } label: {
                    HStack {
                        Text("Contact Support")
                            .multiblur([(10,0.25), (50,0.35)])
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.green)
                    .fontWeight(.bold)
                }
                .background(Color.green.opacity(0.025))
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .tint(.green)
                .frame(maxWidth: .infinity)
                .disabled(showMailComposer)
            }
            .padding()
            .background(Color.black.opacity(0.25))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8){
                    Text("Developers!")
                        .font(.headline)
                    Text("Bugs and feature requests can also be filed as GitHub Issues.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    if let url = URL(string: "http://github.com/ryanwhitney/Control") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("View Control On GitHub")
                            .multiblur([(10,0.25), (50,0.35)])


                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.indigo)
                    .fontWeight(.bold)
                }
                .background(Color.indigo.opacity(0.025))
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .tint(.indigo)
                .frame(maxWidth: .infinity)
                .disabled(showMailComposer)
            }
            .padding()
            .background(Color.black.opacity(0.25))
            .cornerRadius(10)
            HStack{
                Spacer()
                VersionView()
                Spacer()
            }
            Spacer()
        }
        .sheet(isPresented: $showMailComposer) {
            MailComposer(
                isPresented: $showMailComposer,
                subject: "📱 Support Request: Control",
                recipient: "ryan.whitney@me.com",
                body: "\n\n---------\nAbove, please describe the issue you're having or any other feedback you'd like to share. Thanks!"
            )
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitle("Support")

    }
}

private struct VersionView: View {
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    var body: some View {
        Text("Version \(appVersion) (\(buildNumber))")
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}

#Preview {
    SupportPreferenceView()
}
