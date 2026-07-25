import SwiftUI
import MultiBlur

/// What to do about a "Permissions Required" readout: the steps to follow on the
/// Mac and the name to look for once you're there. Instructions only — these are
/// the Mac's settings, so there's nothing for the phone to link to.
struct PermissionsHelpSheet: View {
    let kind: PermissionKind
    @ObservedObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch kind {
        case .automation: return "Allow app control"
        case .accessibility: return "Allow key presses"
        }
    }

    private var explanation: String {
        switch kind {
        case .automation:
            return "Your Mac asks permission for each app Control works with. You only have to do this once."
        case .accessibility:
            return "Your Mac needs permission before Control can press keys for you. You only have to do this once."
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
                Text("Find ") + Text("sshd-keygen-wrapper").bold() + Text(", then turn on the app you want to control."),
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.title2).bold()
                            .accessibilityAddTraits(.isHeader)
                        Text(explanation)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
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
                    Text("Control runs on your phone, never on your Mac — so you won't find it in these lists. sshd-keygen-wrapper is the part of macOS that passes Control's commands along, so that's the name to look for.")
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
