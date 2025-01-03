import SwiftUI

struct AppControl: View {
    let platform: any AppPlatform
    @Binding var state: AppState
    @EnvironmentObject var controller: AppController
    
    var body: some View {
        VStack {
            MediaControlPanel(
                title: platform.name,
                mediaInfo: state.title,
                isPlaying: state.isPlaying,
                actions: platform.supportedActions,
                onAction: { action in
                    Task {
                        await controller.executeAction(platform: platform, action: action)
                    }
                }
            )
        }
        .onAppear {
            Task {
                await controller.updateState(for: platform)
            }
        }
    }
} 

