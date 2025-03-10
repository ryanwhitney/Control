import SwiftUI

struct AboutPreferenceView: View {
    @State private var showMailComposer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16){
                Spacer()
                Image("AppIconAsImage")
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(20)
                    .frame(width: 100, height: 100)
                VStack(alignment: .leading){
                    Text("Control")
                        .font(.title3)
                        .fontWeight(.bold)
                        .fontWidth(.expanded)
                }

                Spacer()
            }

                Text("Control is a free iOS remote control for managing playback of media on a Mac.")
                    Text("Have feedback or feature requests?")
                        .font(.headline)
                    Text("Control is a one-person operation. I'll do be best to respond to your requests as soon as possible.")

                Button {
                    showMailComposer = true
                } label: {
                    HStack{
                        Spacer()
                        Text("Contact me")
                            .font(.headline)
                            .padding(.vertical, 8)
                        Spacer()
                    }

                }
                .frame(maxWidth: .infinity, alignment: .center)
                .buttonStyle(.borderedProminent)


            Spacer()

        }
        .sheet(isPresented: $showMailComposer) {
            MailComposer(
                isPresented: $showMailComposer,
                subject: "📱 Feature Request: Control",
                recipient: "ryan.whitney@me.com",
                body: "\n\n---------\nAbove, please write which Mac apps you'd like to use with Control."
            )
        }
        .padding(.horizontal)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitle("Support")
    }

}


#Preview {
    AboutPreferenceView()
}
