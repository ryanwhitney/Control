import SwiftUI
import MultiBlur

struct FeedbackPreferenceView: View {
    @State private var showMailComposer = false

    var body: some View {
        VStack(spacing:16){
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16){
                    Text("Hi, I'm [Ryan](https://rw.is).")
                    Text("I made Control after getting tired of standing up to make small volume adjustments.")
                    Text("Existing options required separate Mac apps and paid subscriptions.")
                    Text("Instead, Control is designed to not require any additional software. It's free, it's simple, and it usually works.")
                    Text("I’d love to make Control as useful and accessible as possible. Feedback, suggestions, and requests for additional app support are always welcome.")
                }
                .foregroundStyle(.secondary)

                Button {
                    showMailComposer = true
                } label: {
                    HStack {
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
            Spacer()
        }
        .sheet(isPresented: $showMailComposer) {
            MailComposer(
                isPresented: $showMailComposer,
                subject: "📱 Control Feedback",
                recipient: "ryan.whitney@me.com",
                body: "\n"
            )
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitle("Feedback")

    }
}


#Preview {
    FeedbackPreferenceView()
}
