import SwiftUI
import MessageUI

struct MailComposer: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var subject: String
    var recipient: String
    var body: String

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var parent: MailComposer

        init(_ parent: MailComposer) {
            self.parent = parent
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.isPresented = false
            controller.dismiss(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mailVC = MFMailComposeViewController()
        mailVC.mailComposeDelegate = context.coordinator
        mailVC.setSubject(subject)
        mailVC.setToRecipients([recipient])
        mailVC.setMessageBody(body, isHTML: false)
        return mailVC
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
}
