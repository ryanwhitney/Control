import SwiftUI
import WebKit

struct URLWebView: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        if let url = URL(string: urlString) {
            let request = URLRequest(url: url)
            webView.load(request)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No updates needed
    }
}

struct URLWebView_Previews: PreviewProvider {
    static var previews: some View {
        URLWebView(urlString: "https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac")
    }
}
