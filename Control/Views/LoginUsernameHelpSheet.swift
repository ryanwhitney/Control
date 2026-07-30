import SwiftUI

/// Where to find the short macOS user name Control logs in with. Instructions
/// only — the name lives on the Mac, so there's nothing here for the phone to read.
struct LoginUsernameHelpSheet: View {
    private var finderSteps: [Text] {
        [
            Text("Open ") + Text("Finder").bold() + Text(" on your Mac."),
            Text("Press ") + Text("Shift").bold() + Text(" + ") + Text("Command").bold() + Text(" + ") + Text("H").bold() + Text("."),
            Text("You’ll be taken to your “home” folder.") + Text(" This folder’s name is usually the same as your username").bold() + Text("."),
        ]
    }

    private var terminalSteps: [Text] {
        [
            Text("Open the") + Text(" Terminal ").bold() + Text("app on your Mac."),
            Text("Type") + Text(" whoami ").monospaced().bold() + Text("and press ") + Text("Return").bold() + Text("."),
            Text("Your username will be printed."),
        ]
    }

    private var systemInfoSteps: [Text] {
        [
            Text("Hold") + Text(" Option ").bold() + Text("and click on ")
                + Text(Image(systemName: "apple.logo")).accessibilityLabel("the Apple menu").bold()
                + Text(" in the top left corner of your screen."),
            Text("With") + Text(" Option ").bold() + Text("held, the first menu item should be") + Text(" System Information").bold() + Text("."),
            Text("Click") + Text(" System Information ").bold() + Text("and select") + Text(" Software ").bold() + Text("in the left sidebar."),
            Text("Look for") + Text(" User Name ").bold() + Text("in the list of information. The shorter, lowercase name in parentheses at the end of that line is your username."),
        ]
    }

    var body: some View {
        HelpSheet(
            title: "What’s my macOS username?",
            subtitle: "This is surprisingly difficult to find. Here are a few ways to figure it out:",
            mailSubject: "📱 macOS username help/question",
            mailBody: "Let me know what’s happening above and I’ll get back to you as soon as possible.",
            // Three sections of steps: too long to open at `.medium`.
            detents: [.large]
        ) {
            // Tighter than the rest: it follows the subtitle, not a run of steps.
            appHeader("finder-icon", label: "Finder icon", title: "Using Finder:", topPadding: 30)
            HelpSheetSteps(steps: finderSteps)

            appHeader("terminal-icon", label: "Terminal icon", title: "Using Terminal:")
            HelpSheetSteps(steps: terminalSteps)

            appHeader("system-information-icon", label: "System Information icon", title: "Using System Information:")
            HelpSheetSteps(steps: systemInfoSteps)
        }
    }

    private func appHeader(
        _ image: String,
        label: String,
        title: String,
        topPadding: CGFloat = 40
    ) -> some View {
        Section {
            VStack(spacing: 4) {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 100)
                    .accessibilityLabel(label)
                Text(title)
                    .font(.title2).bold()
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.top, topPadding)
        .padding(.bottom, 16)
        .listRowBackground(Color.clear)
        .listSectionSpacing(0)
        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}

#Preview("LoginUsernameHelpSheet") {
    Color.clear.sheet(isPresented: .constant(true)) {
        LoginUsernameHelpSheet()
    }
}
