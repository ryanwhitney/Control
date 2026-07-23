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
    @State private var showingKeyPadEditor = false
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Transport icons ignore Dynamic Type on purpose: platforms with five actions
    // (VLC/IINA/mpv) already fill a small phone's width, so any per-glyph growth
    // pushes the outer buttons off screen with no way to reach them. iPad has the
    // room, so there they grow by controlScale instead (the base 60pt button is
    // already comfortably above tap-target minimums).
    private var primaryIconWidth: CGFloat { 40 * controlScale }
    private var primaryIconHeight: CGFloat { 45 * controlScale }
    private var trackIconWidth: CGFloat { 25 * controlScale }
    private var trackIconHeight: CGFloat { 28 * controlScale }

    private var isPhoneLandscape: Bool {
        verticalSizeClass == .compact
    }

    /// iPad in a roomy (regular width *and* height) layout. Deliberately false for
    /// every iPhone — including Plus/Max phones, which report regular *width* in
    /// landscape but compact height — so phone portrait and landscape sizing are
    /// untouched. Narrow iPad multitasking (compact width) also falls back to phone
    /// sizing, where the scaled-up controls wouldn't fit.
    private var isPad: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    /// How much larger the non-volume controls and their labels grow on iPad. Stays
    /// 1 on phones, so every phone code path below renders exactly as before.
    private var controlScale: CGFloat { isPad ? 1.4 : 1 }

    // The key pad is four rows to the transport row's one, so it takes less of
    // the portrait whitespace above it — otherwise its bottom row lands under the
    // volume slider on a small phone.
    private var isKeyPad: Bool { platform.controlStyle == .keyPad }

    // Phone landscape uses tight 4pt gaps around the readout so the controls get
    // the remaining vertical space, which the key pad sizes its caps from.
    private var titleBottomPadding: CGFloat {
        if isPhoneLandscape { return 4 }
        return (isKeyPad ? 20 : 50) * controlScale
    }

    private var readoutBottomPadding: CGFloat {
        if isPhoneLandscape { return 4 }
        return (isKeyPad ? 24 : 60) * controlScale
    }

    /// "app 3 of 7" while resting on this page; after an adjustment it becomes
    /// "app 4 of 7, Music" so the switch announces where you landed by name.
    private var pagerAccessibilityValue: String {
        let position = "app \(selectedIndex + 1) of \(pageCount)"
        guard selectedIndex != pageIndex else { return position }
        return "\(position), \(selectedName)"
    }

    private var transportRow: some View {
        HStack(spacing: 16 * controlScale) {
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
                .buttonStyle(IconButtonStyle(
                    width: 60 * controlScale,
                    height: 60 * controlScale,
                    fontSize: 36 * controlScale
                ))
                .accessibilityInputLabels(appAction.action.inputLabels)
            }
        }
    }

    var body: some View {
        VStack(spacing: isPhoneLandscape ? 0 : 16 * controlScale) {
            VStack(spacing: isKeyPad ? 0 : 4) {
                HStack {
                    Text(platform.name)
                        .font(isPad ? .title : .body)
                        .fontWeight(.bold)
                        .fontWidth(.expanded)
                        .id(platform.name)
                        .accessibilityValue(pagerAccessibilityValue)
                        .accessibilityAdjustableAction { direction in
                            // Step from the live selection, not this page's own
                            // index: focus stays on the old page's title briefly
                            // after a switch, and stepping from pageIndex there
                            // drops repeat swipes or jumps the wrong way.
                            switch direction {
                            case .increment:
                                onSelectPage(selectedIndex + 1)
                            case .decrement:
                                onSelectPage(selectedIndex - 1)
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
                    if isKeyPad {
                        Button {
                            showingKeyPadEditor = true
                        } label: {
                            Label("Customize Keyboard Controls", systemImage: "gearshape.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, titleBottomPadding)
                VStack(alignment: .center) {
                    Text(state.title)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.center)
                        .id("\(platform.name)_title")
                        .frame(maxWidth: .infinity)
                    if !isKeyPad { Text(state.subtitle)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .id("\(platform.name)_subtitle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityElement(children: .combine)
                .font(isPad ? .title2 : .callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: isPhoneLandscape || isKeyPad ? 0 : 40 * controlScale)
                .padding(.horizontal, isPhoneLandscape || isKeyPad ? 64 : 10)
                .padding(.bottom, readoutBottomPadding)
                .transition(.opacity)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.title)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.subtitle)
            }

            Group {
                switch platform.controlStyle {
                case .transport:
                    transportRow
                case .keyPad:
                    KeyPadControl(platform: platform, isCompact: isPhoneLandscape, sizeScale: controlScale)
                }
            }
            // Landscape: the controls take the remaining height. The key pad uses
            // top alignment (close under the readout); transport rows stay centred.
            .frame(
                maxHeight: isPhoneLandscape ? .infinity : nil,
                alignment: isKeyPad && isPhoneLandscape ? .top : .center
            )
            // The pager's dots overlay its bottom edge, which extends 14pt below
            // its slot in landscape (see ControlView); this clearance keeps caps
            // from under the dots.
            .padding(.bottom, isPhoneLandscape ? 40 : 60 * controlScale)
        }
        .padding(.top, isPhoneLandscape ? 4 : 0)
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
        .sheet(isPresented: $showingKeyPadEditor) {
            KeyPadEditorView()
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
