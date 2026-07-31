import SwiftUI
import MultiBlur

struct PlatformControl: View {
    let platform: any AppPlatform
    @Binding var state: AppState
    /// Lets VoiceOver switch apps from the title, rather than hunting for the
    /// page indicator and losing focus on every change.
    let pageIndex: Int
    let pageCount: Int
    /// The *selected* page, not this one's: the adjustable announcement comes
    /// from the old title's value, which must track the selection or it's stale.
    let selectedIndex: Int
    let selectedName: String
    let onSelectPage: (Int) -> Void
    let titleFocus: AccessibilityFocusState<String?>.Binding
    @EnvironmentObject var controller: AppController
    @StateObject private var preferences = UserPreferences.shared
    @State private var showingExperimentalAlert = false
    @State private var showingKeyPadEditor = false
    @State private var permissionHelpKind: PermissionKind?
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Ignore Dynamic Type on purpose: a five-action row already fills a small
    // phone's width, so growth pushes the outer buttons off screen. iPad has the
    // room, so it grows by controlScale instead.
    private var primaryIconWidth: CGFloat { 40 * controlScale }
    private var primaryIconHeight: CGFloat { 45 * controlScale }
    private var trackIconWidth: CGFloat { 25 * controlScale }
    private var trackIconHeight: CGFloat { 28 * controlScale }

    private var isPhoneLandscape: Bool {
        verticalSizeClass == .compact
    }

    /// Regular width *and* height, so it's false for Plus/Max phones in landscape
    /// (regular width, compact height) and for narrow iPad multitasking, where the
    /// scaled-up controls wouldn't fit.
    private var isPad: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    /// 1 on phones, so no phone path below is affected.
    private var controlScale: CGFloat { isPad ? 1.4 : 1 }

    // Four rows to the transport row's one, so it gets less of the portrait
    // whitespace or its bottom row lands under the volume slider.
    private var isKeyPad: Bool { platform.controlStyle == .keyPad }

    // Landscape keeps these tight so the controls get the remaining height,
    // which the key pad sizes its caps from.
    private var titleBottomPadding: CGFloat {
        if isPhoneLandscape { return 4 }
        return (isKeyPad ? 20 : 50) * controlScale
    }

    /// Sits the fix-it button clear of the readout rather than tucked under it.
    private static let permissionButtonGap: CGFloat = 16
    /// The gap plus roughly the rendered button.
    private static let permissionButtonAllowance: CGFloat = 50

    /// The fix-it button sits in this gap, so the gap gives up its own height
    /// rather than the page growing — the key pad's portrait height is fixed and
    /// anything taller clips off the top.
    private var readoutBottomPadding: CGFloat {
        if isPhoneLandscape { return 4 }
        let base = (isKeyPad ? 24 : 60) * controlScale
        guard state.permissionKind != nil else { return base }
        return max(8, base - Self.permissionButtonAllowance)
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
                            // From the live selection, not this page's index:
                            // focus lingers on the old title after a switch, and
                            // stepping from pageIndex drops repeat swipes.
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
                VStack(spacing: Self.permissionButtonGap) {
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
                    .transition(.opacity)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.title)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.subtitle)

                    // Outside the readout, which combines its children — a
                    // button folded into that can't be activated.
                    if let kind = state.permissionKind {
                        Button {
                            permissionHelpKind = kind
                        } label: {
                            Text("How to fix this")
                                .font(.footnote)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 5)
                                .glassPillLabel()
                                .fontWeight(.bold)
                                .multiblur([(10, 0.25), (50, 0.35)])
                        }
                        .glassPillButtonStyle(tint: .accentColor)
                        .accessibilityHint("Explains which permission to grant on your Mac")
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                }
                .padding(.bottom, readoutBottomPadding)
                // Carries the padding change too, so the controls slide.
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.permissionKind)
            }

            Group {
                switch platform.controlStyle {
                case .transport:
                    transportRow
                case .keyPad:
                    KeyPadControl(platform: platform, isCompact: isPhoneLandscape, sizeScale: controlScale)
                }
            }
            // Landscape: the controls take the remaining height, the key pad
            // top-aligned under the readout and transport rows centred.
            .frame(
                maxHeight: isPhoneLandscape ? .infinity : nil,
                alignment: isKeyPad && isPhoneLandscape ? .top : .center
            )
            // Puts back what the clearance below gave up, so transport rows keep
            // their position while the dots stay lower. The key pad keeps the
            // space: its portrait height is fixed.
            .padding(.top, isPhoneLandscape || isKeyPad ? 0 : 0 * controlScale)
            // Keeps the controls clear of the dots, which overlay the pager's
            // bottom edge 14pt below its slot (see ControlView).
            .padding(.bottom, isPhoneLandscape ? 40 : 40 * controlScale)
        }
        .padding(.top, isPhoneLandscape ? 4 : 0)
        .onAppear {
            Task {
                guard controller.hasCompletedInitialUpdate else { return }
                // ControlView refreshes these when their tab is selected: a paged
                // TabView pre-renders neighbours and would foreground them here.
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
        .sheet(item: $permissionHelpKind) { kind in
            PermissionsHelpSheet(kind: kind)
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
