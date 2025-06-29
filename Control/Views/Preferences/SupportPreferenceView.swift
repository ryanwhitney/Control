import SwiftUI
import MultiBlur

struct SupportPreferenceView: View {
    @State private var showMailComposer = false
    @State private var showingDebugLogs = false
    @StateObject private var debugLogger = DebugLogger.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
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
                        Image(systemName: "envelope")
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
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.indigo)
                    .fontWeight(.bold)
                    .multiblur([(10,0.25), (50,0.35)])
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

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8){
                    HStack(alignment: .firstTextBaseline) {
                        Text("Debug Logs")
                            .font(.headline)
                        Spacer()
                        Text(debugLogger.isLoggingEnabled ? "Enabled" : "Disabled")
                            .font(.caption)
                            .foregroundStyle(debugLogger.isLoggingEnabled ? .green : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(debugLogger.isLoggingEnabled ? .green.opacity(0.1) : .secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    Text("Enable logging to help diagnose connection or app issues.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    showingDebugLogs = true
                } label: {
                    HStack {
                        Text("Open Debug Logs")
                        Image(systemName: "chevron.right")
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.red)
                    .fontWeight(.bold)
                    .multiblur([(10,0.25), (50,0.35)])
                }
                .background(Color.red.opacity(0.025))
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .tint(.red)
                .frame(maxWidth: .infinity)
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
            .padding()
        }
        .sheet(isPresented: $showMailComposer) {
            MailComposer(
                isPresented: $showMailComposer,
                subject: "📱 Support Request: Control",
                recipient: "ryan.whitney@me.com",
                body: "\n\n---------\nAbove, please describe the issue you're having or any other feedback you'd like to share. Thanks!"
            )
        }
        .sheet(isPresented: $showingDebugLogs) {
            DebugLogsView()
        }
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
