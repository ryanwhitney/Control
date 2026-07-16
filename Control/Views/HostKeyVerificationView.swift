import SwiftUI

/// A per-connection detail screen (reached from the Edit sheet) that shows the
/// Mac's trusted SSH host-key fingerprint(s) framed for a non-technical
/// reader, plus a Terminal command to confirm it on the Mac.
/// Purely informational — nothing here changes the connection.
struct HostKeyVerificationView: View {
    let displayName: String
    let trustedKeys: [SavedConnections.TrustedHostKey]

    var body: some View {
        Form {
            Section {
                Text("Every Mac has a unique fingerprint it uses to prove it's really itself. Control checks it each time you connect, to make sure it's really \(displayName) — and not another device pretending to be it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(trustedKeys, id: \.fingerprint) { key in
                keySection(key)
            }
        }
        .navigationTitle("Verify This Mac")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func keySection(_ key: SavedConnections.TrustedHostKey) -> some View {
        HostKeyFingerprintSections(
            fingerprintTitle: "\(displayName)'s Fingerprint",
            displayName: displayName,
            fingerprint: key.fingerprint,
            keyType: key.keyType
        )
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
