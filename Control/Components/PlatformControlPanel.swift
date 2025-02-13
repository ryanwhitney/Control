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
                        .id(platform.name)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    if platform.name.contains("Safari") {
                        Label("Experimental", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                    }
                }
                .animation(.spring(), value: platform.name)
                
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .id(state.title)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.spring(), value: state.title)
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
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: config.staticIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 34, height: 34)
                        }
                    }
                    .buttonStyle(IconButtonStyle())
                }
            }
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
        platform: MusicApp(),
        state: .constant(.init(
            title: "Nothing's Gonna Stop Us Now - Starship",
            isPlaying: true
        ))
    )
    .environmentObject(AppController(sshClient: client, platformRegistry: PlatformRegistry()))
    .padding()
    .preferredColorScheme(.dark)
} 
