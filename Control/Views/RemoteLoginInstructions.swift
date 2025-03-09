import SwiftUI
import AVKit

struct RemoteLoginInstructions: View {
    @State private var player: AVPlayer? = {
        if let bundleUrl = Bundle.main.url(forResource: "remote-login-instructions", withExtension: "mp4") {
            return AVPlayer(url: bundleUrl)
        }
        print("video not found")
        return nil
    }()

    var body: some View {
        VStack{
            List{
                HStack(spacing: 8){
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(.secondary, .tertiary)
                        .font(.system(size: 25))
                    Text("Enable Remote Login:")
                        .font(.title3).bold()
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .listRowSeparator(.hidden)
                .listSectionSpacing(0)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)

                Section{
                    if let player = player {
                        let videoAspectRatio: CGFloat = 1430 / 940 // Calculate aspect ratio
                        VideoPlayer(player: player)
                            .aspectRatio(videoAspectRatio, contentMode: .fit) // Ensures correct aspect ratio
                            .frame(maxWidth: .infinity) // Allows it to fit width while maintaining aspect
                            .onAppear {
                                do {
                                    try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])
                                    try AVAudioSession.sharedInstance().setActive(true)
                                } catch {
                                    print("Failed to set audio session category: \(error)")
                                }

                                player.volume = 0
                                player.seek(to: .zero)
                                player.play()
                                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
                                    player.seek(to: .zero)
                                    player.play()
                                }
                            }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 1, bottom: 10, trailing: 1))
                .listSectionSpacing(10)
                .listRowBackground(Color.clear)

                Section{
                    ForEach(0...4, id: \.self) { index in
                        HStack(alignment: .top) {
                            Text("\(index + 1).")
                                .frame(minWidth: 16, alignment: .leading)
                                .foregroundStyle(.secondary)
                            switch index {
                            case 0:
                                Text("Open ")
                                + Text("System Settings").bold()
                                + Text(".")
                            case 1:
                                Text("Select ")
                                + Text("General").bold()
                                + Text(" on the left panel.")
                            case 2:
                                Text("Scroll to select ")
                                + Text("Sharing").bold()
                                + Text(".")
                            case 3:
                                Text("Enable ")
                                + Text("Remote Login").bold()
                                + Text(" near the bottom.")
                            case 4:
                                Text("Click the ")
                                + Text(Image(systemName: "info.circle"))
                                    .bold()
                                + Text(" icon and disable ")
                                + Text("Allow full disk access").bold()
                                + Text(".")
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
                .listStyle(GroupedListStyle())
                .scrollContentBackground(.hidden)
                .listSectionSpacing(8)

                Section{
                    NavigationLink {
                        URLWebView(urlString: "https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac")
                    } label: {
                        Text("Instructions for older MacOS versions ")
                            .font(.subheadline)

                    }
                }

                Section{
                    HStack( spacing: 8 ){
                        Image(systemName: "2.circle.fill")
                            .foregroundStyle(.secondary, .tertiary)
                            .font(.system(size: 25))
                        Text("Other Steps:")
                            .font(.title3).bold()
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)

                Section{

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName:"tv.badge.wifi.fill")
                            .font(.system(size: 15))
                            .padding(.leading, -10)
                            .frame(minWidth: 16, alignment: .center)
                            .foregroundStyle(.secondary)
                        Text("Make sure both devices are on the same WiFi network.")

                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName:"wifi.exclamationmark.circle.fill")
                            .padding(.leading, -10)
                            .frame(minWidth: 16, alignment: .center)
                            .foregroundStyle(.secondary)
                        Text("If you're using a VPN, ensure it allows local network access.")
                    }

                }
                .listSectionSpacing(0)
                .listStyle(GroupedListStyle())
                .scrollContentBackground(.hidden)

            }

        }
        .navigationBarHidden(true)
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
