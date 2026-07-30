import SwiftUI

/// What to do about a "Permissions Required" readout: the steps to follow on the
/// Mac and the name to look for once you're there. Instructions only — these are
/// the Mac's settings, so there's nothing for the phone to link to.
struct PermissionsHelpSheet: View {
    let kind: PermissionKind

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
        HelpSheet(
            title: title,
            subtitle: explanation,
            mailSubject: mailSubject,
            mailBody: "Let me know what’s happening above and I’ll get back to you as soon as possible. If you’re able to, please also let me know what app you’re trying to control."
        ) {
            HelpSheetSteps(steps: steps)
        } explainer: {
            Text("Why **`sshd-keygen-wrapper`**?")
            Text("Control only runs on your phone, so your Mac can’t permission it by name. `sshd-keygen-wrapper` is the built-in macOS process that Control uses to send commands to your Mac, so that’s what needs permissions enabled.")
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
