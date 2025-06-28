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

    func makeUIViewController(context: Context) -> UIViewController {
        if MFMailComposeViewController.canSendMail() {
            let mailVC = MFMailComposeViewController()
            mailVC.mailComposeDelegate = context.coordinator
            mailVC.setSubject(subject)
            mailVC.setToRecipients([recipient])
            mailVC.setMessageBody(body, isHTML: false)
            return mailVC
        } else {
            // Fallback to mailto
            let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let mailtoString = "mailto:\(recipient)?subject=\(encodedSubject)&body=\(encodedBody)"

            if let mailtoURL = URL(string: mailtoString) {
                UIApplication.shared.open(mailtoURL)
            }

            DispatchQueue.main.async {
                self.isPresented = false
            }

            return UIViewController()
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
