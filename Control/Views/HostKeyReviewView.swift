import SwiftUI
import UIKit

// MARK: - Shared fingerprint UI

/// The inset-grouped-style card the fingerprint screens are built from.
/// Custom cards (instead of Form sections) let these screens pair each
/// explanation with its own action and give the codes real visual weight.
private struct HostKeyPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

/// A fingerprint as a labeled code card: a small caption label, the constant
/// "SHA256:" prefix dimmed, and the code shown exactly as the Mac prints it.
struct FingerprintCodeCard: View {
    let label: String
    let fingerprint: String

    var body: some View {
        HostKeyPanel {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                FingerprintText(fingerprint: fingerprint)
            }
        }
    }
}

/// The fingerprint value: dimmed "SHA256:" prefix, then the code, unaltered
/// so it matches Terminal output character for character. Spelled out for
/// VoiceOver so it can be compared by ear.
struct FingerprintText: View {
    let fingerprint: String
    var prominent = true

    private var parts: (prefix: String, code: String) {
        guard let colon = fingerprint.firstIndex(of: ":") else { return ("", fingerprint) }
        return (String(fingerprint[...colon]), String(fingerprint[fingerprint.index(after: colon)...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !parts.prefix.isEmpty {
                Text(parts.prefix)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(parts.code)
                .font(.system(prominent ? .callout : .footnote, design: .monospaced).weight(prominent ? .medium : .regular))
                .foregroundStyle(prominent ? Color.primary : Color.secondary)
                .textSelection(.enabled)
                .speechSpellsOutCharacters()
        }
    }
}

/// The on-Mac Terminal check as numbered steps a non-technical user can
/// follow — including how to open Terminal at all. The command comes with a
/// copy button and a plain-language breakdown of each part, so users can
/// verify what they're about to run instead of pasting blindly. `resultStep`
/// is each screen's step 3: what to do with the printed result.
struct TerminalCheckCard<ResultStep: View>: View {
    let displayName: String
    let keyPath: String
    @ViewBuilder let resultStep: ResultStep

    var body: some View {
        HostKeyPanel {
            Text("Check it on the Mac")
                .font(.headline)
            NumberedStep(number: 1) {
                Text("Open Terminal on \(displayName). To find it, press Command-Space and type “Terminal”.")
            }
            Divider()
            NumberedStep(number: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste or type this command, then press Return:")
                    CopyableCommand(command: "ssh-keygen -lf \(keyPath)")
                    CommandExplainer(displayName: displayName, keyPath: keyPath)
                }
            }
            Divider()
            NumberedStep(number: 3) {
                resultStep
            }
        }
    }
}

/// A collapsed plain-language breakdown of the verification command, so
/// running it is informed consent rather than blind copy-paste.
private struct CommandExplainer: View {
    let displayName: String
    let keyPath: String

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                CommandPartRow(part: "ssh-keygen", meaning: "Apple's built-in tool for SSH keys")
                CommandPartRow(part: "-lf", meaning: "show the fingerprint of a file")
                CommandPartRow(part: keyPath, meaning: "\(displayName)'s public key")
                Text("It reads one file and prints its fingerprint. It can't install or change anything. It's good practice to know what a command does before running it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("What does this command do?")
                .font(.footnote.weight(.medium))
        }
    }
}

/// One part of the command beside what it means.
private struct CommandPartRow: View {
    let part: String
    let meaning: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(part)
                .font(.system(.footnote, design: .monospaced).weight(.medium))
            Text(meaning)
                .font(.footnote)
                .foregroundStyle(.secondary)
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

/// The verification command as a code chip with a copy button.
private struct CopyableCommand: View {
    let command: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 8)
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
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Review flow

/// The trust decision, pinned to the bottom of the compare page — the place
/// where the user has just checked and knows the answer. The review page
/// instead embeds each path's action in its card and pins only the safe exit.
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

/// Reached from "Verify" on the host-key-change alert. Visually a fork in the
/// road: a "did you change this Mac?" card whose checklist ends in Trust &
/// Reconnect, and a "none of that happened?" card that ends in Compare
/// Fingerprints — each path's action lives with its explanation, and the
/// bottom bar holds only the safe exit. Trusting only takes effect if the
/// reconnect it triggers actually verifies the key.
struct HostKeyReviewView: View {
    let displayName: String
    let newKey: SSHHostKeyInfo
    let previousKeys: [SavedConnections.TrustedHostKey]
    let onTrust: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(displayName) has a new fingerprint.")
                            .font(.title3.weight(.semibold))
                        Text("Every Mac has a unique fingerprint that verifies its identity. A new one usually means the Mac changed, but it can also mean another device is pretending to be it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    HostKeyPanel {
                        Text("Did you recently…")
                            .font(.headline)
                        ChecklistRow(icon: "arrow.clockwise", text: "Reinstall macOS")
                        ChecklistRow(icon: "clock.arrow.circlepath", text: "Restore \(displayName) from a backup")
                        ChecklistRow(icon: "desktopcomputer", text: "Replace it with a new Mac")
                        Text("These changes give a Mac a new fingerprint. If you made one of them, it's safe to reconnect.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(action: onTrust) {
                            Text("Trust & Reconnect")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    HostKeyPanel {
                        Label {
                            Text("None of that happened?")
                                .font(.headline)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text("Don't reconnect yet. Another device could be pretending to be \(displayName) to capture your Mac's password.")
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
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Shows the old and new fingerprints and how to check them on the Mac")
                        Text("This takes about a minute.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Verify This Mac")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(role: .cancel, action: onDecline) {
                    Text("Don't Connect")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .padding()
                .background(.bar)
            }
        }
    }
}

/// One row of the "did you change this Mac?" checklist.
private struct ChecklistRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
        }
    }
}

/// The compare page: one guided flow. The new fingerprint sits inside the
/// Terminal steps as the thing to compare against, and the verdict rows name
/// the exact button to press for each outcome. The previously trusted
/// fingerprint is a collapsed subcase of "it doesn't match", where it has a
/// confident diagnosis: the Mac hasn't changed, the network is lying.
struct HostKeyFingerprintCompareView: View {
    let displayName: String
    let newKey: SSHHostKeyInfo
    let previousKeys: [SavedConnections.TrustedHostKey]
    let onTrust: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This check tells you whether the new fingerprint is really \(displayName)'s.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let path = SSHHostKeyFingerprint.localVerificationPath(for: newKey.keyType) {
                    TerminalCheckCard(displayName: displayName, keyPath: path) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Compare the result with this fingerprint:")
                            FingerprintText(fingerprint: newKey.fingerprint)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }

                    HostKeyPanel {
                        Text("What the result means")
                            .font(.headline)
                        OutcomeRow(
                            symbol: "checkmark.circle.fill",
                            color: .green,
                            title: "It matches",
                            detail: "\(displayName)'s fingerprint really did change. Tap Trust & Reconnect."
                        )
                        Divider()
                        OutcomeRow(
                            symbol: "exclamationmark.triangle.fill",
                            color: .orange,
                            title: "It doesn't match",
                            detail: "This connection isn't reaching \(displayName). Something else on the network is answering for it. Tap Don't Connect and try again later, on a network you trust."
                        )
                        if !previousKeys.isEmpty {
                            Divider()
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(previousKeys, id: \.fingerprint) { key in
                                        FingerprintText(fingerprint: key.fingerprint, prominent: false)
                                    }
                                    Text("If the result matches this one, \(displayName) itself hasn't changed. Something on this network is pretending to be it. Don't connect on this network.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Text("It matches the previous fingerprint")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                } else {
                    // No local file to check against (unknown key type). Show
                    // the new fingerprint so the screen still has its subject.
                    FingerprintCodeCard(label: "New Fingerprint", fingerprint: newKey.fingerprint)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Compare Fingerprints")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            TrustDecisionButtons(onTrust: onTrust, onDecline: onDecline)
        }
    }
}

/// One verdict row: what the Terminal printed → what it means → which button
/// to press next.
private struct OutcomeRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
