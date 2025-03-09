import SwiftUI
import MultiBlur

struct SupportPreferenceView: View {
    @State private var showMailComposer = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing:16){
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8){
                    Text("Found an issue?")
                        .font(.headline)
                    Text("This app includes zero analytics or tracking. If you run into a bug, please let me know and I'll do my best to address it!")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8){
                    Text("Feature requests?")
                        .font(.headline)
                    Text("Control has the ability to support any app with AppleScript support. Feel free to request additional app support or other improvements.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    showMailComposer = true
                } label: {
                    HStack {
                        Text("Contact Support")
                            .multiblur([(10,0.25), (20,0.35), (50,0.5),  (100,0.5)])
                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.green)
                    .fontWeight(.bold)
                }
                .background(Color.green.opacity(0.025))
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .tint(.green)
                .frame(maxWidth: .infinity)
                .disabled(showMailComposer)
            }
            .padding()
            .background(Color.black.opacity(0.25))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8){
                    Text("Developers!")
                        .font(.headline)
                    Text("Bugs and feature requests can also be filed as GitHub Issues.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    if let url = URL(string: "http://github.com/ryanwhitney/Control") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("View Control On GitHub")
                            .multiblur([(10,0.25), (20,0.35), (50,0.5),  (100,0.5)])


                    }
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.indigo)
                    .fontWeight(.bold)
                }
                .background(Color.indigo.opacity(0.025))
                .cornerRadius(12)
                .buttonStyle(.bordered)
                .tint(.indigo)
                .frame(maxWidth: .infinity)
                .disabled(showMailComposer)
            }
            .padding()
            .background(Color.black.opacity(0.25))
            .cornerRadius(10)
            .sheet(isPresented: $showMailComposer) {
                MailComposer(
                    isPresented: $showMailComposer,
                    subject: "📱 Support Request: Control",
                    recipient: "ryan.whitney@me.com",
                    body: "\n\n---------\nAbove, please describe the issue you're having or any other feedback you'd like to share. Thanks!"
                )
            }
            Spacer()
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitle("Support")

    }


}

#Preview {
    SupportPreferenceView()
}
