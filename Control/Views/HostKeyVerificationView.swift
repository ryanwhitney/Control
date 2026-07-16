import SwiftUI

/// A per-connection detail screen (reached from the Edit sheet) that shows the
/// Mac's trusted SSH host-key fingerprint(s) as code cards, plus the Terminal
/// steps to confirm them on the Mac — the same visual language as the
/// mismatch review flow. Purely informational — nothing here changes the
/// connection.
struct HostKeyVerificationView: View {
    let displayName: String
    let trustedKeys: [SavedConnections.TrustedHostKey]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Every Mac has a unique fingerprint that verifies its identity. Control checks it each time you connect to make sure it's really \(displayName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(trustedKeys, id: \.fingerprint) { key in
                    FingerprintCodeCard(
                        label: "Trusted Fingerprint",
                        fingerprint: key.fingerprint
                    )

                    if let path = SSHHostKeyFingerprint.localVerificationPath(for: key.keyType) {
                        TerminalCheckCard(displayName: displayName, keyPath: path) {
                            Text("Confirm that it matches the fingerprint above.")
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Verify This Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        HostKeyVerificationView(
            displayName: "Ryan's MacBook Pro",
            trustedKeys: [
                .init(fingerprint: "SHA256:2Kug8N6AtOj8fzQCKPYKpH6A+7m6U6N5fia5nJY5q7c", keyType: "ssh-ed25519")
            ]
        )
    }
}
