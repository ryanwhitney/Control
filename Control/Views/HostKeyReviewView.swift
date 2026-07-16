import SwiftUI

/// The fingerprint value plus the on-Mac Terminal check. Used by the
/// informational verification screen (reached from Edit) to show a single
/// trusted key. The mismatch review flow has its own compare-focused layout.
struct HostKeyFingerprintSections: View {
    let fingerprintTitle: String
    let displayName: String
    let fingerprint: String
    let keyType: String

    var body: some View {
        Section(fingerprintTitle) {
            // Shown in full and, for VoiceOver, spelled out character by
            // character so it can be compared against the Mac.
            Text(fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .speechSpellsOutCharacters()
        }

        if let path = SSHHostKeyFingerprint.localVerificationPath(for: keyType) {
            Section("Double-Check It") {
                Text("Want to be sure? On \(displayName) itself, open Terminal and run:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("ssh-keygen -lf \(path)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("It should print the same fingerprint shown above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FingerprintText: View {
    let fingerprint: String
    var body: some View {
        // Full and, for VoiceOver, spelled out so it can be compared by ear.
        Text(fingerprint)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .speechSpellsOutCharacters()
    }
}

/// The trust decision, shared by both pages of the review flow so the choice is
/// reachable wherever the user makes up their mind. Labels state the outcome:
/// trusting reconnects and pins the new key; declining connects to nothing.
private struct TrustDecisionButtons: View {
    let onTrust: () -> Void
    let onDecline: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Button(action: onTrust) {
                Text("Trust & Reconnect")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .cancel, action: onDecline) {
                Text("Don't Connect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.bar)
    }
}

/// Reached from "Verify" on the host-key-change alert. A plain-language page: a
/// quick "did you change this Mac?" self-check with trust / don't-connect, and
/// an Advanced link to compare the fingerprints. Trusting only takes effect if
/// the reconnect it triggers actually verifies the key.
struct HostKeyReviewView: View {
    let displayName: String
    let newKey: SSHHostKeyInfo
    let previousKeys: [SavedConnections.TrustedHostKey]
    let onTrust: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Every Mac has a unique fingerprint it uses to prove it's really itself. \(displayName)'s fingerprint has changed since you last connected.")
                        .font(.callout)
                }

                Section("Is this expected?") {
                    Text("A Mac's fingerprint changes when its system is reinstalled or replaced. It's safe to reconnect if you recently:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Reinstalled macOS", systemImage: "arrow.clockwise")
                    Label("Restored \(displayName) from a backup", systemImage: "clock.arrow.circlepath")
                    Label("Set it up as a new Mac with the same name", systemImage: "desktopcomputer")
                }

                Section("Didn't change anything?") {
                    Text("Then don't reconnect yet. Another device on your network could be posing as \(displayName) — reconnecting would hand it your Mac's password. Compare the fingerprints, or check the Mac in person, before you trust it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        HostKeyFingerprintCompareView(
                            displayName: displayName,
                            newKey: newKey,
                            previousKeys: previousKeys,
                            onTrust: onTrust,
                            onDecline: onDecline
                        )
                    } label: {
                        Label("Compare the fingerprints", systemImage: "checkmark.shield")
                    }
                    .accessibilityHint("Advanced: shows the old and new fingerprints and how to check them on the Mac")
                }
            }
            .navigationTitle("Verify This Mac")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                TrustDecisionButtons(onTrust: onTrust, onDecline: onDecline)
            }
        }
    }
}

/// The advanced page: the new and previous fingerprints side by side, the
/// on-Mac command to read the real one, and what each outcome means — including
/// the spoofing case and what to do about it.
struct HostKeyFingerprintCompareView: View {
    let displayName: String
    let newKey: SSHHostKeyInfo
    let previousKeys: [SavedConnections.TrustedHostKey]
    let onTrust: () -> Void
    let onDecline: () -> Void

    var body: some View {
        Form {
            Section {
                Text("Check which fingerprint is real by reading it on \(displayName) directly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Showing now") {
                FingerprintText(fingerprint: newKey.fingerprint)
            }

            if !previousKeys.isEmpty {
                Section("What you trusted before") {
                    ForEach(previousKeys, id: \.fingerprint) { key in
                        FingerprintText(fingerprint: key.fingerprint)
                    }
                }
            }

            if let path = SSHHostKeyFingerprint.localVerificationPath(for: newKey.keyType) {
                Section("Read it on the Mac") {
                    Text("On \(displayName), open Terminal and run:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("ssh-keygen -lf \(path)")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Text("It prints the Mac's fingerprint right now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("What the result means") {
                    Label {
                        Text("If it matches **Showing now**, \(displayName)'s fingerprint really did change. It's safe to reconnect.")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Label {
                        Text("If it prints anything else — even the fingerprint you trusted before — another device is posing as \(displayName). Don't connect, and check the Mac in person.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Compare Fingerprints")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            TrustDecisionButtons(onTrust: onTrust, onDecline: onDecline)
        }
    }
}

#Preview("Review") {
    HostKeyReviewView(
        displayName: "Ryan's MacBook Pro",
        newKey: SSHHostKeyInfo(fingerprint: "SHA256:2Kug8N6AtOj8fzQCKPYKpH6A+7m6U6N5fia5nJY5q7c", keyType: "ssh-ed25519"),
        previousKeys: [.init(fingerprint: "SHA256:0ZhfeRMx5FYwJaKMXuo5um4RQoMu17SCAR2jXU5wFVY", keyType: "ssh-ed25519")],
        onTrust: {},
        onDecline: {}
    )
}

#Preview("Compare") {
    NavigationStack {
        HostKeyFingerprintCompareView(
            displayName: "Ryan's MacBook Pro",
            newKey: SSHHostKeyInfo(fingerprint: "SHA256:2Kug8N6AtOj8fzQCKPYKpH6A+7m6U6N5fia5nJY5q7c", keyType: "ssh-ed25519"),
            previousKeys: [.init(fingerprint: "SHA256:0ZhfeRMx5FYwJaKMXuo5um4RQoMu17SCAR2jXU5wFVY", keyType: "ssh-ed25519")],
            onTrust: {},
            onDecline: {}
        )
    }
}
