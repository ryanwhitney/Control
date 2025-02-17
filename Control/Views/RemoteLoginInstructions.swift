import SwiftUI
import AVKit
import MultiBlur

struct RemoteLoginInstructions: View {
    @State private var player: AVPlayer? = {
        // First try bundle
        if let bundleUrl = Bundle.main.url(forResource: "remote-login", withExtension: "mp4") {
            print("✓ Found video in bundle at: \(bundleUrl)")
            return AVPlayer(url: bundleUrl)
        }
        
        // Then try relative to source
        let sourceUrl = URL(fileURLWithPath: "Resources/remote-login.mp4", relativeTo: Bundle.main.bundleURL)
        if FileManager.default.fileExists(atPath: sourceUrl.path) {
            print("✓ Found video at source path: \(sourceUrl)")
            return AVPlayer(url: sourceUrl)
        }
        
        print("❌ Video not found in bundle or source")
        print("Bundle URL: \(Bundle.main.bundleURL)")
        print("Source URL: \(sourceUrl)")
        return nil
    }()

    @State private var isPlaying: Bool = false

    var body: some View {
        VStack(spacing:0) {
            if let player = player {
                VideoPlayer(player: player)
                    .cornerRadius(13)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(Color.black, lineWidth: 5)
                    )
                    .background(.black)
                    .onAppear {
                        player.seek(to: .zero)
                    }
            } else {
                Text("Video not found")
                    .foregroundColor(.red)
            }

            let steps = ["Open System Settings.", "Select General on the left panel.", "Scroll and select Sharing on the right panel.", "Now that you’re in the Sharing panel, scroll to the bottom and enable Remote Login."]

            List(steps.indices, id: \.self) { index in
                VStack(alignment:.leading){
                HStack(alignment:.top) {
                    Text("\(index + 1).")
                        .frame(minWidth: 16, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(steps[index])
                }
                    if index == 3 {
                        HStack(alignment:.top) {
                            Text("\(index + 1).")
                                .frame(minWidth: 16, alignment: .leading)
                                .foregroundStyle(.clear)
                            HStack(alignment:.top){

                                Group{
                                    Text("Unless you’ve enabled it for other reasons, press the ")
                                    + Text(Image(systemName: "info.circle.fill"))
                                        .font(.caption)
                                    + Text(" icon and disable \"Allow full disk access\"")
                                }
                                .padding(.top,1)
                                .font(.system(size: 15))


                            }
                            .foregroundStyle(.blue)
                            .cornerRadius(10)
                        }
                    }
                }
            }
//            VStack{
//                Button {
//                    print("ok")
//                } label: {
//                    Text("It still isn't working")
//                        .padding(.vertical, 5)
//                        .foregroundStyle(.tint)
//
//                }
//                .buttonStyle(.plain)
//                .tint(.accentColor)
//                .frame(maxWidth: .infinity)
//            }
//            .padding()

        }
        .navigationTitle("Enable Remote Login")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            player?.play()
        }
    }
}

#Preview {
    NavigationView {
        RemoteLoginInstructions()
    }
}
