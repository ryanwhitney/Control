import SwiftUI
import MultiBlur

/// What to do about a "Permissions Required" readout: the steps to follow on the
/// Mac and the name to look for once you're there. Instructions only — these are
/// the Mac's settings, so there's nothing for the phone to link to.
struct PermissionsHelpSheet: View {
    @State private var showMailComposer = false

    let kind: PermissionKind
    @ObservedObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch kind {
        case .automation: return "Automation permission needed"
        case .accessibility: return "Accessibility permission needed"
        }
    }

    private var explanation: String {
        switch kind {
        case .automation:
            return "Your Mac asks permission for each app Control works with. You only have to do this once."
        case .accessibility:
            return "These controls need Accessibility permissions to send key presses to your Mac. You only have to do this once."
        }
    }
    
    private var mailSubject: String {
        switch kind {
        case .automation: return "📱 Automation permissions help/question"
        case .accessibility: return "📱 Accessibility permissions help/question"
        }
    }

    /// Emphasis baked in, matching the Remote Login steps.
    private var steps: [Text] {
        let openSettings = Text("Open ") + Text("System Settings").bold() + Text(" on your Mac.")
        switch kind {
        case .automation:
            return [
                openSettings,
                Text("Go to ") + Text("Privacy & Security").bold() + Text(", then ") + Text("Automation").bold() + Text("."),
                Text("Find ") + Text("sshd-keygen-wrapper").bold() + Text(", then turn on the apps you want to control as well as ") + Text("System Events").bold() + Text("."),
            ]
        case .accessibility:
            return [
                openSettings,
                Text("Go to ") + Text("Privacy & Security").bold() + Text(", then ") + Text("Accessibility").bold() + Text("."),
                Text("Turn on ") + Text("sshd-keygen-wrapper").bold() + Text("."),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title)
                            .font(.title2).bold()
                            .accessibilityAddTraits(.isHeader)
                        Text(explanation)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                .listRowBackground(Color.clear)

                Section {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top) {
                            Text("\(index + 1).")
                                .frame(minWidth: 16, alignment: .leading)
                                .foregroundStyle(.secondary)
                            step
                        }
                        .padding(.vertical, 6)
                        // One instruction, not a stray number.
                        .accessibilityElement(children: .combine)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing:16){
                        Text("Why **`sshd-keygen-wrapper`**?")
                        Text("Control only runs on your phone, so your Mac can't permission it by name. `sshd-keygen-wrapper` is the built-in macOS process that Control uses to send commands to your Mac, so that's what needs permissions enabled.")
                        Button {
                            showMailComposer = true
                        } label: {
                            (Text("Have any questions, or need a hand? ")
                                .foregroundStyle(.secondary)
                                + Text("Email me anytime.")
                                .foregroundStyle(.tint))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                        
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
            }
            // No `.listStyle`: the platform default draws the rounded inset
            // card, while `.grouped` would run the steps edge to edge.
            .scrollContentBackground(.hidden)
            .listSectionSpacing(8)

            Button {
                dismiss()
            } label: {
                HStack {
                    Text("OK")
                        .multiblur([(10, 0.25), (50, 0.35)])
                }
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .glassPillLabel()
                .fontWeight(.bold)
            }
            // Not `.accentColor`, which reads the asset catalog and comes out
            // blue whatever the theme.
            .glassPillButtonStyle(tint: preferences.tintColorValue)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .background(.ultraThickMaterial)
        .tint(preferences.tintColorValue)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showMailComposer) {
            MailComposer(
                isPresented: $showMailComposer,
                subject: mailSubject,
                recipient: "ryan.whitney@me.com",
                body: "\n\n\n\n--\nLet me know what's happening above and I'll get back to you as soon as possible. It's helpful to know in advance what app you're trying to control."
            )
        }
    }
}

#Preview("Accessibility") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PermissionsHelpSheet(kind: .accessibility)
    }
}

#Preview("Automation") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PermissionsHelpSheet(kind: .automation)
    }
}
