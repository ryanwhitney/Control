import SwiftUI
import MultiBlur

struct FeedbackPreferenceView: View {
    @State private var showMailComposer = false

    var body: some View {
        VStack(spacing:16){
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16){
                    Text("Hi there, I'm [Ryan](https://rw.is).")
                        .foregroundStyle(.secondary)
                    Text("I made this because I wanted a remote control for watching movies on my Mac and existing options required paying fees or installing extra applications on it.")
                        .foregroundStyle(.secondary)
                    Text("Please share any feedback you have. I’d love to make Control as useful and accessible as possible.")
                        .foregroundStyle(.secondary)
                }
                
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
