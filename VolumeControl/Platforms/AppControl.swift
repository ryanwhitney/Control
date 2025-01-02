import SwiftUI

struct AppControl: View {
    let platform: any AppPlatform
    @Binding var state: AppState
    @EnvironmentObject var controller: AppController
    
    var skipInterval: Int {
        switch platform {
        case is MusicApp: return 1
        case is QuickTimeApp: return 5
        case is TVApp: return 10
        default: return 10
        }
    }
    
    var usePlayPauseIcon: Bool {
        switch platform {
        case is VLCApp: return true
        default: return false
        }
    }
    
    var body: some View {
        VStack {
            MediaControlPanel(
                title: platform.name,
                mediaInfo: state.title,
                isPlaying: state.isPlaying,
                skipInterval: skipInterval,
                onBackward: { controller.executeAction(platform: platform, action: .skipBackward(skipInterval)) },
                onPlayPause: { controller.executeAction(platform: platform, action: .playPauseToggle) },
                onForward: { controller.executeAction(platform: platform, action: .skipForward(skipInterval)) },
                usePlayPauseIcon: usePlayPauseIcon
            )
        }
        .onAppear {
            controller.updateState(for: platform)
        }
    }
} 
