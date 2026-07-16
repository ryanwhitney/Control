import SwiftUI
import UIKit

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
            TerminalCheckSection(
                displayName: displayName,
                keyPath: path,
                resultInstruction: "Check that it prints the same fingerprint shown above."
            )
        }
    }
}

/// The on-Mac Terminal check, spelled out as numbered steps a non-technical
/// user can follow — including how to open Terminal at all. Shared by the
/// compare screen and the Edit-flow info screen; `resultInstruction` is each
/// screen's step 3 (what to do with the printed fingerprint). The footer is
/// the trust-building part: the command ships with macOS and only reads.
struct TerminalCheckSection: View {
    let displayName: String
    let keyPath: String
    let resultInstruction: String

    var body: some View {
        Section {
            NumberedStep(number: 1) {
                Text("On \(displayName), open **Terminal** — press ⌘ Space and type “Terminal”.")
            }
            NumberedStep(number: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Copy this command, paste or type it there, and press Return:")
                    CopyableCommand(command: "ssh-keygen -lf \(keyPath)")
                }
            }
            NumberedStep(number: 3) {
                Text(resultInstruction)
            }
        } header: {
            Text("Check It on the Mac")
        } footer: {
            Text("ssh-keygen is built into every Mac. This command only reads the key file and prints its fingerprint — it doesn't change anything.")
        }
    }
}

/// A step number in a filled circle beside the step's instructions.
private struct NumberedStep<Content: View>: View {
    let number: Int
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.secondary)
            content
        }
        .font(.callout)
    }
}

/// The verification command with a copy button, so it can be pasted into
/// Terminal (Universal Clipboard) instead of retyped — pasting is also the
/// guardrail against mistyping the command.
private struct CopyableCommand: View {
    let command: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = command
                withAnimation { copied = true }
                resetTask?.cancel()
                resetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
    }
}

/// A section header with a status dot, so "which fingerprint is which"
/// survives glancing back and forth between the phone and the Mac. Orange =
/// the unverified key being presented now; gray = what was trusted before.
/// Deliberately not green or the app tint — the new key hasn't earned a
/// trusted look yet.
private struct FingerprintStateHeader: View {
    let title: String
    let dotColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(dotColor)
                .accessibilityHidden(true)
            Text(title)
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
/// a Compare Fingerprints link inside the "didn't change anything?" section so
/// the cautious path ends in an action. Trusting only takes effect if the
/// reconnect it triggers actually verifies the key.
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
                }

                Section("Is this expected?") {
                    Text("A Mac's fingerprint changes when its system is reinstalled or replaced. It's safe to reconnect if you recently:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Reinstalled macOS", systemImage: "arrow.clockwise")
                    Label("Restored \(displayName) from a backup", systemImage: "clock.arrow.circlepath")
                    Label("Set it up as a new Mac with the same name", systemImage: "desktopcomputer")
                }

                Section {
                    Text("Don't reconnect yet — another device on your network could be posing as \(displayName), and reconnecting would hand it your Mac's password.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        HostKeyFingerprintCompareView(
                            displayName: displayName,
                            newKey: newKey,
                            previousKeys: previousKeys,
                            onTrust: onTrust,
                            onDecline: onDecline
                        )
                    } label: {
                        Label("Compare Fingerprints", systemImage: "magnifyingglass")
                    }
                    .accessibilityHint("Shows the old and new fingerprints and how to check them on the Mac")
                } header: {
                    Text("Didn't change anything?")
                } footer: {
                    Text("Comparing takes about a minute and tells you for sure.")
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

/// The compare page: the new and previous fingerprints with status-dot
/// headers, the numbered on-Mac Terminal check, and what each outcome means —
/// including the spoofing case and what to do about it.
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

            Section {
                FingerprintText(fingerprint: newKey.fingerprint)
            } header: {
                FingerprintStateHeader(title: "Showing Now", dotColor: .orange)
            }

            if !previousKeys.isEmpty {
                Section {
                    ForEach(previousKeys, id: \.fingerprint) { key in
                        FingerprintText(fingerprint: key.fingerprint)
                    }
                } header: {
                    FingerprintStateHeader(title: "What You Trusted Before", dotColor: .gray)
                }
            }

            if let path = SSHHostKeyFingerprint.localVerificationPath(for: newKey.keyType) {
                TerminalCheckSection(
                    displayName: displayName,
                    keyPath: path,
                    resultInstruction: "Compare what it prints with the fingerprints above."
                )

                Section("What the result means") {
                    Label {
                        Text("If it matches **Showing Now**, \(displayName)'s fingerprint really did change. It's safe to reconnect.")
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
