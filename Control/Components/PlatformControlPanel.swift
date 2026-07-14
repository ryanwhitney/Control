import SwiftUI

struct PlatformControl: View {
    let platform: any AppPlatform
    @Binding var state: AppState
    /// Position of this page in the pager plus a way to move it, so VoiceOver can
    /// switch apps from the title (swipe up/down) instead of hunting for the page
    /// indicator and losing focus on every page change.
    let pageIndex: Int
    let pageCount: Int
    /// The *currently selected* page and its app name — not this page's own. The
    /// adjustable announcement comes from the focused (old) title's value, so the
    /// value must track the selection or VoiceOver reads a stale position.
    let selectedIndex: Int
    let selectedName: String
    let onSelectPage: (Int) -> Void
    let titleFocus: AccessibilityFocusState<String?>.Binding
    @EnvironmentObject var controller: AppController
    @StateObject private var preferences = UserPreferences.shared
    @State private var showingExperimentalAlert = false
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Fixed icon frames, scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var primaryIconWidth: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var primaryIconHeight: CGFloat = 45
    @ScaledMetric(relativeTo: .largeTitle) private var trackIconWidth: CGFloat = 25
    @ScaledMetric(relativeTo: .largeTitle) private var trackIconHeight: CGFloat = 28

    private var isPhoneLandscape: Bool {
        verticalSizeClass == .compact
    }

    /// "app 3 of 7" while resting on this page; after an adjustment it becomes
    /// "app 4 of 7, Music" so the switch announces where you landed by name.
    private var pagerAccessibilityValue: String {
        let position = "app \(selectedIndex + 1) of \(pageCount)"
        guard selectedIndex != pageIndex else { return position }
        return "\(position), \(selectedName)"
    }

    var body: some View {
        VStack(spacing: isPhoneLandscape ? 0 : 16) {
            VStack(spacing: 4) {
                HStack {
                    Text(platform.name)
                        .fontWeight(.bold)
                        .fontWidth(.expanded)
                        .id(platform.name)
                        .accessibilityValue(pagerAccessibilityValue)
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment:
                                onSelectPage(pageIndex + 1)
                            case .decrement:
                                onSelectPage(pageIndex - 1)
                            @unknown default:
                                break
                            }
                        }
                        .accessibilityFocused(titleFocus, equals: platform.id)
                    if platform.experimental {
                        Button {
                            showingExperimentalAlert = true
                        } label: {
                            Label("Experimental", systemImage: "flask.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.tint)
                                .rotationEffect(Angle(degrees: 20.0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, isPhoneLandscape ? 10 : 50)
                VStack(alignment: .center) {
                    Text(state.title)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.center)
                        .id("\(platform.name)_title")
                        .frame(maxWidth: .infinity)
                    Text(state.subtitle)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .id("\(platform.name)_subtitle")
                        .frame(maxWidth: .infinity)
                }
                // One swipe stop for the whole now-playing readout.
                .accessibilityElement(children: .combine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .padding(.horizontal, isPhoneLandscape ? 64 : 10)
                .padding(.bottom, isPhoneLandscape ? 20 : 60)
                .transition(.opacity)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.title)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.subtitle)
            }

            HStack(spacing: 16) {
                ForEach(platform.supportedActions) { appAction in
                    Button {
                        Task {
                            await controller.executeActionWithStatus(platform: platform, action: appAction.action)
                        }
                    } label: {
                        if let dynamicIcon = appAction.dynamicIcon, let isPlaying = state.isPlaying {
                            Image(systemName: dynamicIcon(isPlaying))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: primaryIconWidth, height: primaryIconHeight)
                                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                        } else {
                            if appAction.staticIcon == "forward.end.fill" || appAction.staticIcon == "backward.end.fill" {
                                Image(systemName: appAction.staticIcon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: trackIconWidth, height: trackIconHeight)
                                    .accessibilityLabel(appAction.label)
                            } else {
                                Image(systemName: appAction.staticIcon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: primaryIconWidth, height: primaryIconHeight)
                                    .accessibilityLabel(appAction.label)
                            }
                        }
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityInputLabels(appAction.action.inputLabels)
                }
            }
            .padding(.bottom, isPhoneLandscape ? 40 : 60)
        }
        .onAppear {
            Task {
                // Wait until the initial batch update has completed
                guard controller.hasCompletedInitialUpdate else { return }
                // Foreground-only apps (IINA/mpv) are refreshed by ControlView when
                // their tab is the active selection — not here, since a paged
                // TabView pre-renders adjacent panels and would foreground them.
                guard platform.checksStatusOnlyWhenVisible == false else { return }
                await controller.updateState(for: platform)
            }
        }
        .alert("\(platform.name) support is experimental", isPresented: $showingExperimentalAlert) {
            Button("OK") { }
        } message: {
            Text(platform.reasonForExperimental)
        }
    }
}

private struct PlatformControlPreviewHost: View {
    @AccessibilityFocusState private var titleFocus: String?

    var body: some View {
        PlatformControl(
            platform: SafariApp(),
            state: .constant(.init(
                title: "Skin",
                subtitle: "Wild Powwers",
                isPlaying: true
            )),
            pageIndex: 0,
            pageCount: 1,
            selectedIndex: 0,
            selectedName: "Safari",
            onSelectPage: { _ in },
            titleFocus: $titleFocus
        )
    }
}

#Preview {
    let client = SSHClient()
    client.connect(
        host: ProcessInfo.processInfo.environment["ENV_HOST"] ?? "",
        username: ProcessInfo.processInfo.environment["ENV_USER"] ?? "",
        password: ProcessInfo.processInfo.environment["ENV_PASS"] ?? ""
    ) { _ in }

    return PlatformControlPreviewHost()
        .environmentObject(AppController(sshClient: client, platformRegistry: PlatformRegistry()))
        .padding()
        .preferredColorScheme(.dark)
}
