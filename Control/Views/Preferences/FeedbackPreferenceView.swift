import SwiftUI
import MultiBlur
import StoreKit

struct FeedbackPreferenceView: View {
    @State private var showMailComposer = false

    var body: some View {
        ScrollView {
            VStack(spacing:16){
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16){
                    Text("Hi, I'm [Ryan](https://rw.is).")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("I made Control for my own convenience after growing tired of not being able to press pause or adjust my Mac's volume from afar.")
                    Text("Other apps required companion desktop apps and often paid subscriptions.")
                    Text("Control is instead designed to not require any additional software. Use it once and it's ready anytime. No preparation needed.")
                    Text("It's free, it's simple, and it usually works!")
                    Text("I hope Control can be useful to others as well. Please feel free to reach out anytime with feedback, requests for additional apps, or anything else.")
                    Text(" –RW").fontWidth(.expanded).fontWeight(.bold).font(.footnote)
                }
                .foregroundStyle(.secondary)

                Button {
                    showMailComposer = true
                } label: {
                    HStack {
                        Image(systemName: "envelope")
                            .accessibilityHidden(true)
                        Text("Send Feedback")
                            .multiblur([(10,0.25), (50,0.35)])
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .glassPillLabel()
                    .fontWeight(.bold)
                }
                .glassPillButtonStyle(tint: .accentColor)
                .frame(maxWidth: .infinity)
                .disabled(showMailComposer)
            }
            .padding()
            .background(Color.black.opacity(0.25))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8){
                    Text("Enjoying Control?")
                        .font(.headline)
                    Text("Only you can help us escape a \\*huge\\* pile of TV remote apps in the App Store. Reviews are much appreciated. 🙂")
                        .foregroundStyle(.secondary)
                }
                Button {
                    if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                        SKStoreReviewController.requestReview(in: scene)
                    }
                } label: {
                    HStack {
                        Image(systemName: "star.fill")
                            .accessibilityHidden(true)
                        Text("Review on App Store")
                            .multiblur([(10,0.25), (50,0.35)])
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .glassPillLabel()
                    .fontWeight(.bold)
                }
                .glassPillButtonStyle(tint: .orange)
                .frame(maxWidth: .infinity)
            }
            .padding()
            .background(Color.black.opacity(0.25))
            .cornerRadius(10)
            Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showMailComposer) {
            MailComposer(
                isPresented: $showMailComposer,
                subject: "📱 Control Feedback",
                recipient: "ryan.whitney@me.com",
                body: "\n"
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitle("Feedback")

    }
}


#Preview {
    FeedbackPreferenceView()
}
