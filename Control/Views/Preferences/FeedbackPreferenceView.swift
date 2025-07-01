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
                    Text("I made Control after getting tired of standing up to hit pause or lower the volume. Existing options required separate companion apps and paid subscriptions.")
                    Text("Instead, Control is designed to not require any additional software on your Mac.")
                    Text("It's free, it's simple, and it usually works!")
                    Text("Any feedback or requests for additional apps are always welcome. I want to make Control as useful and accessible as possible.")
                }
                .foregroundStyle(.secondary)

                Button {
                    showMailComposer = true
                } label: {
                    HStack {
                        Image(systemName: "envelope")
                        Text("Send Feedback")
                            .multiblur([(10,0.25), (50,0.35)])
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.tint)
                    .tint(.accentColor)
                    .fontWeight(.bold)
                }
                .background(Color.accentColor.opacity(0.025))
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .tint(.accentColor)
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
                        Text("Review on App Store")
                            .multiblur([(10,0.25), (50,0.35)])
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.orange)
                    .fontWeight(.bold)
                }
                .background(Color.orange.opacity(0.025))
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .tint(.orange)
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
