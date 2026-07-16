import SwiftUI

/// A per-connection detail screen (reached from the Edit sheet) that shows the
/// Mac's SSH host-key fingerprint(s) framed for a non-technical reader as a
/// "verification code", plus a Terminal command to confirm it on the Mac.
/// Purely informational — nothing here changes the connection.
struct HostKeyVerificationView: View {
    let displayName: String
    let trustedKeys: [SavedConnections.TrustedHostKey]

    var body: some View {
        Form {
            Section {
                Text("Each Mac holds a set of unique keys generated when MacOS installs. Control checks these when you connect to confirm your commands reach the right machine and not another device pretending to be it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(trustedKeys, id: \.fingerprint) { key in
                keySection(key)
            }
        }
        .navigationTitle("Verification Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func keySection(_ key: SavedConnections.TrustedHostKey) -> some View {
        Section("\(displayName)'s Fingerprint") {
            // Shown in full and, for VoiceOver, spelled out character by
            // character so it can actually be compared against the Mac —
            // the whole point of the screen — rather than described.
            Text(key.fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .speechSpellsOutCharacters()
        }

        if let path = SSHHostKeyFingerprint.localVerificationPath(for: key.keyType) {
            Section("Double-Check It") {
                Text("Want to be sure? On \(displayName) itself, open Terminal and run:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("ssh-keygen -lf \(path)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("It should print the same code shown above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
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
