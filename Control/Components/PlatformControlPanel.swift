import SwiftUI

struct PlatformControl: View {
    let platform: any AppPlatform
    @Binding var state: AppState
    @EnvironmentObject var controller: AppController
    @StateObject private var preferences = UserPreferences.shared
    @State private var showingExperimentalAlert = false
    @Environment(\.verticalSizeClass) var verticalSizeClass

    private var isPhoneLandscape: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        VStack(spacing: isPhoneLandscape ? 0 : 16) {
            VStack(spacing: 4) {
                HStack {
                    Text(platform.name)
                        .fontWeight(.bold)
                        .fontWidth(.expanded)
                        .id(platform.name)
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
                    if !state.title.isEmpty {
                        Text(state.title)
                            .lineLimit(1)
                            .id("\(platform.name)_title")
                            .contentTransition(.opacity)
                            .animation(.spring(), value: state.subtitle)
                    }

                    if !state.subtitle.isEmpty {
                        Text(state.subtitle)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .id("\(platform.name)_subtitle")
                            .contentTransition(.opacity)
                            .animation(.spring(), value: state.subtitle)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minHeight: 40)
                .padding(.bottom, isPhoneLandscape ? 20 : 60)
            }

            HStack(spacing: 16) {
                ForEach(platform.supportedActions) { appAction in
                    Button {
                        Task {
                            await controller.executeAction(platform: platform, action: appAction.action)
                        }
                    } label: {
                        if let dynamicIcon = appAction.dynamicIcon, let isPlaying = state.isPlaying {
                            Image(systemName: dynamicIcon(isPlaying))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 45)
                                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                        } else {
                            if appAction.staticIcon == "forward.end.fill" || appAction.staticIcon == "backward.end.fill" {
                                Image(systemName: appAction.staticIcon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 25, height: 28)
                                    .accessibilityLabel(appAction.label)
                            } else {
                                Image(systemName: appAction.staticIcon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 40, height: 45)
                                    .accessibilityLabel(appAction.label)
                            }
                        }
                    }
                    .buttonStyle(IconButtonStyle())
                }
            }
            .padding(.bottom, isPhoneLandscape ? 40 : 60)
        }
        .onAppear {
            Task {
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

#Preview {
    let client = SSHClient()
    client.connect(
        host: ProcessInfo.processInfo.environment["ENV_HOST"] ?? "",
        username: ProcessInfo.processInfo.environment["ENV_USER"] ?? "",
        password: ProcessInfo.processInfo.environment["ENV_PASS"] ?? ""
    ) { _ in }

    return PlatformControl(
        platform: SafariApp(),
        state: .constant(.init(
            title: "Skin",
            subtitle: "Wild Powwers",
            isPlaying: true
        ))
    )
    .environmentObject(AppController(sshClient: client, platformRegistry: PlatformRegistry()))
    .padding()
    .preferredColorScheme(.dark)
}
