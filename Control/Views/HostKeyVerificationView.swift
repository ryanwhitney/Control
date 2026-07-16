import SwiftUI

/// A per-connection detail screen (reached from the Edit sheet) that shows the
/// Mac's SSH host-key fingerprint framed for a non-technical reader as a
/// "verification code", plus an optional Terminal command for anyone who wants
/// to confirm it directly on the Mac. Purely informational — nothing here
/// changes the connection.
struct HostKeyVerificationView: View {
    let displayName: String
    let fingerprint: String
    let keyType: String?

    /// The local file to inspect on the Mac, if the key type maps to one.
    private var verificationPath: String? {
        keyType.flatMap { SSHHostKeyFingerprint.localVerificationPath(for: $0) }
    }

    var body: some View {
        Form {
            Section {
                Text("Every Mac has its own verification code. Control checks \(displayName)'s code each time you connect, so your commands always reach the right computer — not another device pretending to be it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("\(displayName)'s Code") {
                Text(fingerprint)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Verification code")
                    .accessibilityValue(spokenFingerprint)
                    .accessibilityHint("Long press to copy")
            }

            if let path = verificationPath {
                Section {
                    Text("Want to be sure? On \(displayName) itself, open Terminal and run:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("ssh-keygen -lf \(path)")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("Terminal command")
                        .accessibilityHint("Long press to copy")
                    Text("It should print the same code shown above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Double-Check It")
                }
            }
        }
        .navigationTitle("Verification Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// VoiceOver reads the raw `SHA256:…` string as gibberish; announce it as a
    /// code the user can compare rather than spelling every character.
    private var spokenFingerprint: String {
        "A verification code. Double tap and hold to copy it, then compare it with the code on your Mac."
    }
}

#Preview {
    NavigationStack {
        HostKeyVerificationView(
            displayName: "Ryan's MacBook Pro",
            fingerprint: "SHA256:2Kug8N6AtOj8fzQCKPYKpH6A+7m6U6N5fia5nJY5q7c",
            keyType: "ssh-ed25519"
        )
    }
}
