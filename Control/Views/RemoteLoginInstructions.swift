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

    /// Scale the two fixed icon sizes with Dynamic Type.
    @ScaledMetric(relativeTo: .title3) private var headerIconSize: CGFloat = 25
    @ScaledMetric(relativeTo: .body) private var infoIconSize: CGFloat = 15

    /// The numbered "Enable Remote Login" steps, with their bold emphasis baked in.
    private let remoteLoginSteps: [Text] = [
        Text("Open ") + Text("System Settings").bold() + Text(" on your Mac."),
        Text("Select ") + Text("General").bold() + Text(" on the left panel."),
        Text("Scroll to select ") + Text("Sharing").bold() + Text("."),
        Text("Enable ") + Text("Remote Login").bold() + Text(" near the bottom."),
        Text("Click the ") + Text(Image(systemName: "info.circle")).accessibilityLabel("info").bold()
            + Text(" icon and") + Text(" disable ").bold() + Text("“Allow full disk access”."),
    ]

    var body: some View {
        List {
            stepHeader(1, "Enable Remote Login:")

            Section {
                if let player {
                    let videoAspectRatio: CGFloat = 1430 / 940
                    VideoPlayer(player: player)
                        .aspectRatio(videoAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        // The player's internal controls otherwise become the
                        // accessibility elements and the description is never
                        // read; flatten to one described element with play/pause
                        // as its action.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Screen recording with no audio, showing how to find and enable Remote Login in System Settings on macOS. The same steps are listed below.")
                        .accessibilityHint("Double tap to play or pause")
                        .accessibilityAction {
                            if player.timeControlStatus == .playing {
                                player.pause()
                            } else {
                                player.play()
                            }
                        }
                        .onAppear { startLooping(player) }
                }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 1, bottom: 10, trailing: 1))
            .listSectionSpacing(10)
            .listRowBackground(Color.clear)

            Section {
                ForEach(Array(remoteLoginSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top) {
                        Text("\(index + 1).")
                            .frame(minWidth: 16, alignment: .leading)
                            .foregroundStyle(.secondary)
                        step
                    }
                }
            }
            .listStyle(GroupedListStyle())
            .scrollContentBackground(.hidden)
            .listSectionSpacing(8)

            Section {
                NavigationLink {
                    URLWebView(urlString: "https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac")
                } label: {
                    Text("Instructions for older MacOS versions ")
                        .font(.subheadline)
                }
            }

            stepHeader(2, "Other Steps:", verticalPadding: 16)

            Section {
                infoRow("tv.badge.wifi.fill", "Make sure both devices are on the same WiFi network.")
                infoRow("wifi.exclamationmark.circle.fill", "If you're using a VPN, ensure it allows local network access.")
            }
            .listSectionSpacing(0)
            .listStyle(GroupedListStyle())
            .scrollContentBackground(.hidden)

            stepHeader(3, "Troubleshooting:", verticalPadding: 16, topInset: 32)

            Section {
                infoRow("building.2.fill", "Control may not work on large networks such as those used by hotels, offices, or universities. Connecting the Mac via Personal Hotspot is a workaround.")
                infoRow("lock.shield.fill", "Control won't work with devices that have Lockdown Mode enabled.")
            }
            .listSectionSpacing(0)
            .listStyle(GroupedListStyle())
            .scrollContentBackground(.hidden)
        }
        .navigationBarHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !UIAccessibility.isReduceMotionEnabled {
                player?.play()
            }
        }
    }

    /// A centered, numbered section header (e.g. "1  Enable Remote Login:").
    private func stepHeader(_ number: Int, _ title: String, verticalPadding: CGFloat = 0, topInset: CGFloat = 0) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.secondary, .tertiary)
                .font(.system(size: headerIconSize))
                .accessibilityHidden(true)
            Text(title)
                .font(.title3).bold()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: topInset, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
    }

    /// An icon + text row used by the "Other Steps" and "Troubleshooting" lists.
    private func infoRow(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: infoIconSize))
                .padding(.leading, -6)
                .frame(minWidth: 16, alignment: .center)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
        }
    }

    /// Mutes the player and loops it, keeping playback silent regardless of the ringer.
    private func startLooping(_ player: AVPlayer) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }

        player.volume = 0
        player.seek(to: .zero)
        // Autoplay unless Reduce Motion is on; then the user starts playback
        // themselves (player controls, or the VoiceOver double-tap action) and
        // the loop below keeps it going from there.
        if !UIAccessibility.isReduceMotionEnabled {
            player.play()
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
            player.seek(to: .zero)
            player.play()
        }
    }
}

#Preview {
    NavigationView {
        RemoteLoginInstructions()
    }
}
