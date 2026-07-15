import SwiftUI
import AVKit
import Combine

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

    /// Loop-observer token, paired add/remove so observers can't accumulate
    /// (each block retains the player — an unremoved one leaks it).
    @State private var loopObserver: (any NSObjectProtocol)?
    /// One-time playback setup flag, so a row re-appear (scroll-back, or
    /// popping the older-macOS page) doesn't reset a video the user started.
    @State private var hasConfiguredPlayback = false
    /// Mirrors the player's timeControlStatus so the play overlay tracks
    /// pauses we didn't initiate (backgrounding, interruptions) too.
    @State private var isPlaying = false

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
                    InlineVideoPlayer(player: player)
                        .aspectRatio(videoAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        // AVKit's own touch handling is dead weight with its
                        // controls disabled; the whole surface is our tap target.
                        .allowsHitTesting(false)
                        .overlay {
                            if !isPlaying {
                                playOverlay(player)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { togglePlayback(player) }
                        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                            isPlaying = status != .paused
                        }
                        // One described element for the whole player, with
                        // play/pause as its action — the overlay and the hosted
                        // view never surface individually.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Screen recording with no audio, showing how to find and enable Remote Login in System Settings on macOS. The same steps are listed below.")
                        .accessibilityHint("Plays or pauses the video")
                        .accessibilityInputLabels(["Video", "Play video", "Pause video"])
                        .accessibilityAction { togglePlayback(player) }
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
        // Screen-level teardown: dropping the observer here releases the player
        // when the sheet goes away. (startLooping re-registers on return from a
        // pushed page without re-running the one-time setup.)
        .onDisappear {
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
            }
            loopObserver = nil
        }
    }

    /// Our own play affordance for the paused state: AVKit's control overlay
    /// renders its buttons without glyphs in this List context (the reason
    /// native controls are off — see InlineVideoPlayer). Interactive Liquid
    /// Glass on iOS 26+, the ultra-thin-material look on earlier versions.
    @ViewBuilder
    private func playOverlay(_ player: AVPlayer) -> some View {
        let icon = Image(systemName: "play.fill")
            .font(.system(size: 24))
            .foregroundStyle(.white)
            .padding(22)

        if #available(iOS 26.0, *) {
            Button {
                togglePlayback(player)
            } label: {
                icon
            }
            .buttonStyle(.plain)
            // Clear, not regular: the app forces dark mode, and regular
            // glass's dark variant renders flat gray over the bright video.
            // Clear is the over-media variant — translucent in both schemes.
            .glassEffect(.clear.interactive(), in: .circle)
        } else {
            Button {
                togglePlayback(player)
            } label: {
                icon.background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func togglePlayback(_ player: AVPlayer) {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
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

    /// Mutes the player and loops it, keeping playback silent regardless of the
    /// ringer. Setup runs once per presentation; the loop observer is
    /// re-registered whenever the row appears with none active (its removal
    /// lives in the screen-level onDisappear).
    private func startLooping(_ player: AVPlayer) {
        if !hasConfiguredPlayback {
            hasConfiguredPlayback = true
            do {
                try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Failed to set audio session category: \(error)")
            }

            player.volume = 0
            player.seek(to: .zero)
            // Autoplay unless Reduce Motion or Auto-Play Video Previews says
            // not to; then the user starts playback themselves (the play
            // overlay, or the VoiceOver double-tap action) and the loop below
            // keeps it going from there.
            if !UIAccessibility.isReduceMotionEnabled && UIAccessibility.isVideoAutoplayEnabled {
                player.play()
            }
        }

        guard loopObserver == nil else { return }
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
            player.seek(to: .zero)
            player.play()
        }
    }
}

/// Video surface with no native controls: AVKit's control overlay draws its
/// buttons without glyphs inside a `List` row (broken since iOS 16, with
/// `VideoPlayer` and hosted AVPlayerViewController alike), so the view above
/// supplies its own play overlay and tap-to-toggle instead.
private struct InlineVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        // No PiP for a silent tutorial loop, and keep it out of Now Playing /
        // lock-screen controls.
        controller.allowsPictureInPicturePlayback = false
        controller.updatesNowPlayingInfoCenter = false
        // Clear, not AVKit's default black, so subpixel aspect rounding can't
        // show black hairlines against the clear list row.
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

#Preview {
    NavigationView {
        RemoteLoginInstructions()
    }
}
