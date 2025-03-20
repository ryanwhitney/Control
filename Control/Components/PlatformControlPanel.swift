import SwiftUI

struct PlatformControl: View {
    let platform: any AppPlatform
    @Binding var state: AppState
    @EnvironmentObject var controller: AppController
    @StateObject private var preferences = UserPreferences.shared
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                HStack {
                    Text(platform.name)
                        .fontWeight(.bold)
                        .fontWidth(.expanded)
                        .padding(.bottom, 50)
                        .id(platform.name)
                    if platform.name.contains("Safari") {
                        Label("Experimental", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                    }
                }
                VStack(alignment: .center) {
                    if !state.title.isEmpty {
                        Text(state.title)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .id("\(platform.name)_\(state.title)")
                            .transition(.opacity)
                            .animation(.spring(), value: state.title)
                    }

                    if !state.subtitle.isEmpty {
                        Text(state.subtitle)
                            .font(.callout)
                            .lineLimit(1)
                            .id("\(platform.name)_\(state.subtitle)")
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: state.subtitle)
                    }
                }
                .frame(minHeight: 40)
                .foregroundStyle(.secondary)
                .padding(.bottom, 60)
            }
            
            HStack(spacing: 16) {
                ForEach(platform.supportedActions) { config in
                    Button(action: {
                        Task {
                            await controller.executeAction(platform: platform, action: config.action)
                        }
                    }) {
                        if let dynamicIcon = config.dynamicIcon, let isPlaying = state.isPlaying {
                            Image(systemName: dynamicIcon(isPlaying))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 45)
                        } else {
                            if config.staticIcon == "forward.end.fill" || config.staticIcon == "backward.end.fill" {
                                Image(systemName: config.staticIcon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 25, height: 28)
                            }
                            else {
                                Image(systemName: config.staticIcon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 40, height: 45)
                            }
                        }
                    }
                    .buttonStyle(IconButtonStyle())
                }
            }
            .padding(.bottom, 60)
        }
        .onAppear {
            Task {
                await controller.updateState(for: platform)
            }
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
        platform: VLCApp(),
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
