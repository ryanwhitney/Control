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
                .font(.system(.callout, design: .monospaced).weight(.medium))
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
                Text("It makes no changes to the Mac.")
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

/// Copies text to the clipboard, flipping to a checkmark briefly.
private struct CopyButton: View {
    let text: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            UIPasteboard.general.string = text
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

/// The verification command as a code chip with a copy button.
private struct CopyableCommand: View {
    let command: String

    var body: some View {
        // The command never wraps: rendering it as a single scrollable line
        // is itself the message that it goes into Terminal as one line.
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
            }
            CopyButton(text: command)
        }
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The on-Mac errand as one labeled card: where to do it, the two steps, the
/// command ready to copy, and what the command is, so running it is informed
/// consent rather than blind copy-paste.
private struct MacStepsCard: View {
    let displayName: String
    let command: String

    var body: some View {
        HostKeyPanel {
            Text("On \(displayName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            NumberedStep(number: 1) {
                Text("Open Terminal. Press Command-Space and type “Terminal”.")
            }
            Divider()
            NumberedStep(number: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste this command as one line and press Return.")
                    CopyableCommand(command: command)
                    Text("As a rule, never paste a command you don't understand. This one reads the fingerprint and changes nothing on the Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The command runs ssh-keygen, part of the software every Mac uses for Remote Login.")
                            Text("The \"-lf\" part asks for the fingerprint of a file, and the file is \(displayName)'s public identity key.")
                            Text("You can look the command up anywhere. It's the standard way to read an SSH fingerprint.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Learn more about ssh-keygen")
                            .font(.callout.weight(.medium))
                    }
                }
            }
        }
    }
}

/// What the Mac will print, as a labeled card. The fingerprint is
/// highlighted; the surrounding fields (key size, comment, key type) are
/// dimmed because they vary by Mac and don't matter to the comparison.
private struct ExpectedOutputCard: View {
    let displayName: String
    let fingerprint: String
    let keyType: String
    @Environment(\.colorScheme) private var colorScheme

    private var keyTypeLabel: String {
        if keyType.contains("ed25519") { return "ED25519" }
        if keyType.contains("ecdsa") { return "ECDSA" }
        return keyType.uppercased()
    }

    private var keyBits: String {
        if keyType.hasSuffix("nistp384") { return "384" }
        if keyType.hasSuffix("nistp521") { return "521" }
        return "256"
    }

    private var line: NSAttributedString {
        let dim: [NSAttributedString.Key: Any] = [
            .font: FingerprintTypography.font,
            .foregroundColor: UIColor.secondaryLabel,
            .paragraphStyle: FingerprintTypography.paragraph,
        ]
        let code: [NSAttributedString.Key: Any] = [
            .font: FingerprintTypography.font,
            .foregroundColor: UIColor.label,
            .backgroundColor: UIColor.systemYellow.withAlphaComponent(colorScheme == .dark ? 0.5 : 0.35),
            .paragraphStyle: FingerprintTypography.paragraph,
        ]
        let result = NSMutableAttributedString(string: "\(keyBits) ", attributes: dim)
        result.append(NSAttributedString(string: fingerprint, attributes: code))
        result.append(NSAttributedString(string: " no comment (\(keyTypeLabel))", attributes: dim))
        return result
    }

    /// VoiceOver spells out only the fingerprint; the surrounding fields are
    /// read as words since they don't take part in the comparison.
    private var lineAccessibility: NSAttributedString {
        let result = NSMutableAttributedString(string: "Fingerprint: ")
        result.append(NSAttributedString(
            string: fingerprint,
            attributes: [.accessibilitySpeechSpellOut: true]
        ))
        return result
    }

    var body: some View {
        HostKeyPanel {
            Text("The Mac should print")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            CharacterWrappingText(
                attributedText: line,
                accessibilityAttributedLabel: lineAccessibility
            )
            Text("**If it prints the highlighted fingerprint**, this really is \(displayName). It's safe to reconnect.")
                .font(.callout)
            Text("**If anything else appears**, whatever answered isn't your Mac. Don't connect.")
                .font(.callout)
        }
    }
}

/// A fingerprint as one monospaced run, typeset the way it appears inside
/// Terminal's output line, so the comparison is character for character with
/// nothing reformatted and nothing inserted at line breaks.
private struct InlineFingerprintCard: View {
    let fingerprint: String

    var body: some View {
        CharacterWrappingText(
            attributedText: NSAttributedString(string: fingerprint, attributes: [
                .font: FingerprintTypography.font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: FingerprintTypography.paragraph,
            ]),
            accessibilityAttributedLabel: NSAttributedString(
                string: fingerprint,
                attributes: [.accessibilitySpeechSpellOut: true]
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

// MARK: - Review flow

// MARK: - Fingerprint check flow

/// Everything the guided check needs, threaded through its pages. `host` is
/// the saved hostname or address — its shape (IP, .local, remote name) picks
/// which conclusions apply. `similarNamedNearby` holds names of Macs on the
/// network right now whose names stem-match this one, so conclusion pages
/// can state an observed fact instead of a hypothesis.
private struct HostKeyCheckContext {
    let displayName: String
    let host: String
    let newKey: SSHHostKeyInfo
    let previousKeys: [SavedConnections.TrustedHostKey]
    let similarNamedNearby: [String]
    let onTrust: () -> Void
    let onDecline: () -> Void
}

/// The observed-fact line for the conclusion pages: a similarly named Mac is
/// on the network right now, which turns "this can happen when…" copy into
/// evidence the user can act on.
private struct SimilarMacNotice: View {
    let names: [String]

    var body: some View {
        if let first = names.first {
            Text(names.count > 1
                 ? "Macs named “\(first)” and “\(names[1])” are also on this network right now."
                 : "A Mac named “\(first)” is also on this network right now.")
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
        }
    }
}

/// Shared layout for the check pages: optional symbol, centered title and
/// subtitle in large type, content, and pinned actions. One thing per page,
/// so nothing competes for attention.
private struct CheckStepLayout<Content: View, Actions: View>: View {
    var symbol: String? = nil
    var symbolColor: Color = .accentColor
    let title: String
    var subtitle: String? = nil
    var onCancel: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(symbolColor)
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                content
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                actions
            }
            .padding()
            .background(.bar)
        }
    }
}

/// A full-width label for the check pages' primary action buttons, sized to
/// match the app's main buttons (headline bold, tall tap target).
private struct CheckActionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.headline)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
    }
}

/// A smaller label for the quiet escape actions, so they read as side doors
/// rather than competing with the primary decision.
private struct QuietActionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

/// Shared typography for fingerprints: monospaced at body size, wrapped at
/// any character with hyphenation off, so nothing is inserted at a line
/// break and short fields share lines instead of being pushed out by word
/// wrapping.
private enum FingerprintTypography {
    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.hyphenationFactor = 0
        return style
    }

    static var font: UIFont {
        UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .medium))
    }
}

/// UILabel-backed text for fingerprint display. SwiftUI's Text hyphenates
/// when it breaks a long run, which would put dashes inside a code being
/// compared character for character; UILabel with byCharWrapping breaks
/// cleanly anywhere.
private struct CharacterWrappingText: UIViewRepresentable {
    let attributedText: NSAttributedString
    var accessibilityAttributedLabel: NSAttributedString? = nil

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = attributedText
        label.accessibilityAttributedLabel = accessibilityAttributedLabel
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }
}

/// The fingerprint on its own card, sized for a page with room to breathe.
private struct FingerprintDisplayCard: View {
    let fingerprint: String
    var body: some View {
        FingerprintText(fingerprint: fingerprint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

/// Entry to the guided check. Routes to the steps, or to a minimal manual
/// page for key types without a known local file (not expected in practice).
private struct HostKeyCheckEntry: View {
    let context: HostKeyCheckContext

    var body: some View {
        if let path = SSHHostKeyFingerprint.localVerificationPath(for: context.newKey.keyType) {
            HostKeyCheckGetFingerprint(context: context, keyPath: path)
        } else {
            // A page that cannot explain how to verify must not lead with
            // trust, so both outcomes carry equal weight here.
            CheckStepLayout(
                title: "Check the fingerprint",
                subtitle: "Read the fingerprint on \(context.displayName) itself and compare it with this one.",
                onCancel: context.onDecline
            ) {
                FingerprintDisplayCard(fingerprint: context.newKey.fingerprint)
            } actions: {
                Button(action: context.onTrust) { CheckActionLabel(title: "Trust & Reconnect") }
                    .buttonStyle(.bordered)
                Button(role: .cancel, action: context.onDecline) { CheckActionLabel(title: "Don't Connect") }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Design B's errand page: only the errand. The fingerprint waits on the
/// next page so this page has one job, and the forward button reports a real
/// action instead of a generic Continue.
private struct HostKeyCheckGetFingerprint: View {
    let context: HostKeyCheckContext
    let keyPath: String

    var body: some View {
        CheckStepLayout(
            title: "Have the Mac print its fingerprint",
            subtitle: "The network can lie about who's answering. The Mac's own screen can't.",
            onCancel: context.onDecline
        ) {
            MacStepsCard(
                displayName: context.displayName,
                command: "ssh-keygen -lf \(keyPath)"
            )
        } actions: {
            NavigationLink {
                HostKeyCheckDoesItMatch(context: context)
            } label: {
                CheckActionLabel(title: "I Ran It")
            }
            .buttonStyle(.borderedProminent)
            NavigationLink {
                HostKeyVerifyLater(context: context)
            } label: {
                QuietActionLabel(title: "I Can't Check Right Now")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// The question. The user reports what Terminal printed and gets only the
/// conclusion that applies. Yes and No carry equal weight: they are factual
/// reports, not a recommendation and an alternative, and prominence on the
/// affirmative would nudge the trusting answer.
private struct HostKeyCheckDoesItMatch: View {
    let context: HostKeyCheckContext

    /// Only a previously trusted key of the same type can ever match the
    /// Terminal output, since the command reads that type's key file.
    /// Comparing against another type's fingerprint is structurally
    /// impossible, so those keys are excluded from the follow-up question.
    private var comparablePreviousKeys: [SavedConnections.TrustedHostKey] {
        context.previousKeys.filter { $0.keyType == context.newKey.keyType }
    }

    var body: some View {
        CheckStepLayout(
            title: "Did it print this fingerprint?",
            subtitle: "It's the long code in the middle of the printed line. Every character counts.",
            onCancel: context.onDecline
        ) {
            InlineFingerprintCard(fingerprint: context.newKey.fingerprint)
        } actions: {
            NavigationLink {
                HostKeyCheckMatched(context: context)
            } label: {
                CheckActionLabel(title: "Yes")
            }
            .buttonStyle(.bordered)
            NavigationLink {
                if comparablePreviousKeys.isEmpty {
                    HostKeyCheckNotReaching(context: context)
                } else {
                    HostKeyCheckPreviousQuestion(context: context, comparableKeys: comparablePreviousKeys)
                }
            } label: {
                CheckActionLabel(title: "No")
            }
            .buttonStyle(.bordered)
            NavigationLink {
                HostKeyCheckCommandHelp(context: context)
            } label: {
                QuietActionLabel(title: "Terminal Printed an Error")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Conclusion for a match: the change is genuine, reconnecting is safe.
private struct HostKeyCheckMatched: View {
    let context: HostKeyCheckContext

    var body: some View {
        CheckStepLayout(
            symbol: "checkmark.circle.fill",
            symbolColor: .green,
            title: "This really is \(context.displayName)",
            subtitle: "It's safe to reconnect. Control will trust this fingerprint once it reconnects.",
            onCancel: context.onDecline
        ) {
            EmptyView()
        } actions: {
            Button(action: context.onTrust) { CheckActionLabel(title: "Trust & Reconnect") }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Follow-up question when a previously trusted fingerprint of the same key
/// type exists. Asking directly separates "my network is lying" from "I'm
/// not reaching my Mac", so each ends in an unconditional conclusion.
private struct HostKeyCheckPreviousQuestion: View {
    let context: HostKeyCheckContext
    let comparableKeys: [SavedConnections.TrustedHostKey]

    var body: some View {
        CheckStepLayout(
            title: "Does it match this one?",
            subtitle: "This is the fingerprint Control had saved for \(context.displayName).",
            onCancel: context.onDecline
        ) {
            VStack(spacing: 12) {
                ForEach(comparableKeys, id: \.fingerprint) { key in
                    InlineFingerprintCard(fingerprint: key.fingerprint)
                }
            }
        } actions: {
            NavigationLink {
                HostKeyCheckSpoofed(context: context)
            } label: {
                CheckActionLabel(title: "Yes, This One")
            }
            .buttonStyle(.bordered)
            NavigationLink {
                HostKeyCheckNotReaching(context: context)
            } label: {
                CheckActionLabel(title: "No")
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Conclusion: the Mac still holds the saved key, so whatever answered the
/// connection is a different device. Stated as fact because it is one; the
/// intent behind it is not knowable, so both the innocent and hostile
/// readings are named.
private struct HostKeyCheckSpoofed: View {
    let context: HostKeyCheckContext

    /// The likely benign explanation depends on how the connection names its
    /// Mac: an address is a lease another device can inherit, a .local name
    /// can be shared, a remote name can stop pointing home.
    private var explanation: String {
        switch HostProvenance(host: context.host) {
        case .ipAddress:
            return "This can happen when another device is now using this address, or when a network is intercepting connections. Connect again on a network you trust and Control will check again."
        case .localHostname:
            return "This can happen when another computer shares \(context.displayName)'s name, or when a network is intercepting connections. Connect again on a network you trust and Control will check again."
        case .remoteHostname:
            return "This can happen when \(context.host) no longer points to your Mac, or when a network is intercepting connections. Connect again on a network you trust and Control will check again."
        }
    }

    var body: some View {
        CheckStepLayout(
            symbol: "exclamationmark.triangle.fill",
            symbolColor: .orange,
            title: "Don't connect for now",
            subtitle: "\(context.displayName) still has the fingerprint Control saved. Whatever answered this connection is a different device.",
            onCancel: context.onDecline
        ) {
            VStack(spacing: 12) {
                SimilarMacNotice(names: context.similarNamedNearby)
                Text(explanation)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
        } actions: {
            Button(action: context.onDecline) { CheckActionLabel(title: "Don't Connect") }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Conclusion: whatever answered isn't the Mac. Names the two causes the
/// user can act on, and admits the top human failure mode (the command ran
/// on the wrong Mac) instead of asserting certainty.
private struct HostKeyCheckNotReaching: View {
    let context: HostKeyCheckContext

    /// The actionable repair depends on how the connection names its Mac.
    private var secondStep: String {
        switch HostProvenance(host: context.host) {
        case .ipAddress:
            return "Your router may have given this address to a different device. Look for \(context.displayName) by name in Control's device list, or check its current address in System Settings on the Mac."
        case .localHostname:
            return "If two Macs share the same name, give one a new name in System Settings, then connect again."
        case .remoteHostname:
            return "Make sure \(context.host) still points to this Mac, then connect again."
        }
    }

    var body: some View {
        CheckStepLayout(
            symbol: "exclamationmark.triangle.fill",
            symbolColor: .orange,
            title: "Don't connect yet",
            subtitle: "Terminal printed a fingerprint Control hasn't seen before. This connection probably isn't reaching \(context.displayName).",
            onCancel: context.onDecline
        ) {
            VStack(spacing: 12) {
                SimilarMacNotice(names: context.similarNamedNearby)
                HostKeyPanel {
                    NumberedStep(number: 1) {
                        Text("Make sure you ran the command on \(context.displayName) itself, not another Mac.")
                    }
                    Divider()
                    NumberedStep(number: 2) {
                        Text(secondStep)
                    }
                }
            }
        } actions: {
            Button(action: context.onDecline) { CheckActionLabel(title: "Don't Connect") }
                .buttonStyle(.borderedProminent)
            if let keyPath = SSHHostKeyFingerprint.localVerificationPath(for: context.newKey.keyType) {
                NavigationLink {
                    HostKeyCheckGetFingerprint(context: context, keyPath: keyPath)
                } label: {
                    QuietActionLabel(title: "Check Again")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// Deferral endpoint: the user can't run the check right now (headless Mac,
/// Mac in another room, away from home). Security posture is exactly
/// "decline"; what this page adds is the contract: the connection is blocked,
/// not broken, nothing is trusted, and here is how to resume.
private struct HostKeyVerifyLater: View {
    let context: HostKeyCheckContext

    var body: some View {
        CheckStepLayout(
            title: "Verify when you can",
            subtitle: "Control won't connect to \(context.displayName) until the new fingerprint is verified. Nothing is trusted in the meantime.",
            onCancel: context.onDecline
        ) {
            Text("When you can get to \(context.displayName), tap it in Control and choose Review to pick up where you left off.")
                .font(.callout)
                .multilineTextAlignment(.center)
        } actions: {
            Button(action: context.onDecline) { CheckActionLabel(title: "OK") }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The "Terminal printed an error" branch: the command likely didn't run as
/// written. Try Again pops back to the match question with the command
/// re-copyable right here.
private struct HostKeyCheckCommandHelp: View {
    let context: HostKeyCheckContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CheckStepLayout(
            title: "Check the command",
            subtitle: "An error usually means the command didn't run as written.",
            onCancel: context.onDecline
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let keyPath = SSHHostKeyFingerprint.localVerificationPath(for: context.newKey.keyType) {
                    CopyableCommand(command: "ssh-keygen -lf \(keyPath)")
                }
                Text("Use the copy button, paste it into Terminal, and press Return.")
                    .font(.callout)
            }
        } actions: {
            Button(action: { dismiss() }) { CheckActionLabel(title: "Try Again") }
                .buttonStyle(.borderedProminent)
            NavigationLink {
                HostKeyVerifyLater(context: context)
            } label: {
                QuietActionLabel(title: "I Can't Check Right Now")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// PROTOTYPE: two candidate mismatch flows are being compared on device.
/// Design A is a two-page flow (decision, then optional verification);
/// Design B is the guided wizard. Each presentation of the sheet picks one
/// at random, so cancelling and reconnecting re-rolls. Remove the enum and
/// the switch once a direction is chosen.
private enum HostKeyFlowPrototype: CaseIterable {
    case decisionFirst  // Design A
    case guidedCheck    // Design B
}

/// Reached from "Review…" on the host-key-change alert. Cancel is always in
/// the corner, and trusting only takes effect if the reconnect it triggers
/// actually verifies the key.
struct HostKeyReviewView: View {
    let displayName: String
    let host: String
    let newKey: SSHHostKeyInfo
    let previousKeys: [SavedConnections.TrustedHostKey]
    let similarNamedNearby: [String]
    let onTrust: () -> Void
    let onDecline: () -> Void

    @State private var prototype: HostKeyFlowPrototype =
        HostKeyFlowPrototype.allCases.randomElement() ?? .decisionFirst

    var body: some View {
        let context = HostKeyCheckContext(
            displayName: displayName,
            host: host,
            newKey: newKey,
            previousKeys: previousKeys,
            similarNamedNearby: similarNamedNearby,
            onTrust: onTrust,
            onDecline: onDecline
        )
        NavigationStack {
            switch prototype {
            case .decisionFirst:
                HostKeyDecisionPage(context: context)
            case .guidedCheck:
                HostKeyCheckStart(context: context)
            }
        }
    }
}

/// Confirmation before trusting without a completed fingerprint check, since
/// one tap reconnects and sends the Mac's password to whatever answers. The
/// trust actions that follow a verified match skip this: the user already
/// did the work, and re-asking would punish diligence.
private struct TrustConfirmation: ViewModifier {
    let displayName: String
    @Binding var isPresented: Bool
    let onTrust: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Trust the new fingerprint?",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Trust & Reconnect") { onTrust() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Control will replace the fingerprint it saved for \(displayName) once it reconnects.")
        }
    }
}

// MARK: - Design A: decision page + verify page

/// Design A, page 1: the decision. Two scannable blocks do the triage a
/// wizard would ask page by page, in the same order as the buttons they
/// license. "Fingerprint" is not introduced until the verify page, where it
/// names the code being compared.
private struct HostKeyDecisionPage: View {
    let context: HostKeyCheckContext
    @State private var confirmingTrust = false

    var body: some View {
        CheckStepLayout(
            title: "Trust This Mac?",
            onCancel: context.onDecline
        ) {
            VStack(spacing: 12) {
                HostKeyPanel {
                    Text("Reinstalled, restored, replaced, or started from a different disk?")
                        .font(.headline)
                    Text("Any of those gives a Mac a new fingerprint. This change is expected, and it's safe to reconnect.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HostKeyPanel {
                    Text("Didn't change anything?")
                        .font(.headline)
                    Text("Another device could be posing as \(context.displayName). Control stopped before signing in, so nothing was shared. Verify before you trust.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button(action: { confirmingTrust = true }) { CheckActionLabel(title: "Trust & Reconnect") }
                .buttonStyle(.borderedProminent)
                .modifier(TrustConfirmation(
                    displayName: context.displayName,
                    isPresented: $confirmingTrust,
                    onTrust: context.onTrust
                ))
            NavigationLink {
                HostKeyVerifyPage(context: context)
            } label: {
                CheckActionLabel(title: "Verify First")
            }
            .buttonStyle(.bordered)
            Text("Design A")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Design A, page 2: the answer sheet. One page, two labeled cards, one
/// spatial story: do this on the Mac, expect this back, decide. The subtitle
/// carries the reason the check settles anything. Both buttons carry equal
/// weight because only the user knows the check's result.
private struct HostKeyVerifyPage: View {
    let context: HostKeyCheckContext

    private var keyPath: String? {
        SSHHostKeyFingerprint.localVerificationPath(for: context.newKey.keyType)
    }

    var body: some View {
        CheckStepLayout(
            title: "Ask the Mac Itself",
            subtitle: keyPath != nil
                ? "A connection can be faked. What \(context.displayName) shows on its own screen can't be."
                : "Read the fingerprint on \(context.displayName) itself and compare it with this one.",
            onCancel: context.onDecline
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let keyPath {
                    MacStepsCard(
                        displayName: context.displayName,
                        command: "ssh-keygen -lf \(keyPath)"
                    )
                    ExpectedOutputCard(
                        displayName: context.displayName,
                        fingerprint: context.newKey.fingerprint,
                        keyType: context.newKey.keyType
                    )
                } else {
                    FingerprintDisplayCard(fingerprint: context.newKey.fingerprint)
                    Text("If the fingerprint matches, this really is \(context.displayName) and it's safe to reconnect. If it doesn't, whatever answered isn't your Mac. Don't connect.")
                        .font(.callout)
                }
                Text("If you can't check right now, cancel. Control won't connect until you verify.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button(action: context.onTrust) { CheckActionLabel(title: "Trust & Reconnect") }
                .buttonStyle(.bordered)
            Button(role: .cancel, action: context.onDecline) { CheckActionLabel(title: "Don't Connect") }
                .buttonStyle(.bordered)
        }
    }
}

// MARK: - Design B: guided wizard

/// First page: what happened, and the one question that splits the benign
/// case from the suspicious one.
private struct HostKeyCheckStart: View {
    let context: HostKeyCheckContext

    var body: some View {
        CheckStepLayout(
            title: "The fingerprint doesn't match",
            subtitle: "Every Mac has a unique fingerprint, and Control checks it each time you connect. \(context.displayName) answered with a different one, so Control stopped before signing in.",
            onCancel: context.onDecline
        ) {
            Text("Was this Mac recently reinstalled, restored, replaced, or started from a different disk?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        } actions: {
            NavigationLink {
                HostKeyCheckExpectedChange(context: context)
            } label: {
                CheckActionLabel(title: "Yes")
            }
            .buttonStyle(.bordered)
            NavigationLink {
                HostKeyCheckEntry(context: context)
            } label: {
                CheckActionLabel(title: "No or Not Sure")
            }
            .buttonStyle(.bordered)
            Text("Design B")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The user said they changed the Mac: confirm what that means and offer the
/// informed trust, with a quiet path into the check for the cautious.
private struct HostKeyCheckExpectedChange: View {
    let context: HostKeyCheckContext
    @State private var confirmingTrust = false

    var body: some View {
        CheckStepLayout(
            title: "That explains it",
            subtitle: "Reinstalling, restoring, replacing, or starting from a different disk gives a Mac a new fingerprint. Control will trust the new one once it reconnects.",
            onCancel: context.onDecline
        ) {
            EmptyView()
        } actions: {
            Button(action: { confirmingTrust = true }) { CheckActionLabel(title: "Trust & Reconnect") }
                .buttonStyle(.borderedProminent)
                .modifier(TrustConfirmation(
                    displayName: context.displayName,
                    isPresented: $confirmingTrust,
                    onTrust: context.onTrust
                ))
            NavigationLink {
                HostKeyCheckEntry(context: context)
            } label: {
                QuietActionLabel(title: "Check the Fingerprint Anyway")
            }
            .buttonStyle(.borderless)
        }
    }
}

private let previewContext = HostKeyCheckContext(
    displayName: "Ryan's MacBook Pro",
    host: "Ryans-MacBook-Pro.local",
    newKey: SSHHostKeyInfo(fingerprint: "SHA256:2Kug8N6AtOj8fzQCKPYKpH6A+7m6U6N5fia5nJY5q7c", keyType: "ssh-ed25519"),
    previousKeys: [.init(fingerprint: "SHA256:0ZhfeRMx5FYwJaKMXuo5um4RQoMu17SCAR2jXU5wFVY", keyType: "ssh-ed25519")],
    similarNamedNearby: [],
    onTrust: {},
    onDecline: {}
)

private let previewContextWithNearby = HostKeyCheckContext(
    displayName: "Mac mini",
    host: "192.168.1.50",
    newKey: SSHHostKeyInfo(fingerprint: "SHA256:2Kug8N6AtOj8fzQCKPYKpH6A+7m6U6N5fia5nJY5q7c", keyType: "ssh-ed25519"),
    previousKeys: [.init(fingerprint: "SHA256:0ZhfeRMx5FYwJaKMXuo5um4RQoMu17SCAR2jXU5wFVY", keyType: "ssh-ed25519")],
    similarNamedNearby: ["Mac mini (2)"],
    onTrust: {},
    onDecline: {}
)

#Preview("Design A: decision") {
    NavigationStack {
        HostKeyDecisionPage(context: previewContext)
    }
}

#Preview("Design A: verify") {
    NavigationStack {
        HostKeyVerifyPage(context: previewContext)
    }
}

#Preview("Design B: wizard") {
    NavigationStack {
        HostKeyCheckStart(context: previewContext)
    }
}

#Preview("Design B: doesn't match") {
    NavigationStack {
        HostKeyCheckPreviousQuestion(
            context: previewContext,
            comparableKeys: previewContext.previousKeys
        )
    }
}

#Preview("Design B: not reaching") {
    NavigationStack {
        HostKeyCheckNotReaching(context: previewContext)
    }
}

#Preview("Not reaching, IP + nearby Mac") {
    NavigationStack {
        HostKeyCheckNotReaching(context: previewContextWithNearby)
    }
}
