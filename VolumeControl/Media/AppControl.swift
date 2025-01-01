import SwiftUI

struct AppControl: View {
    let platform: any AppPlatform
    @Binding var state: AppState
    @EnvironmentObject var controller: AppController
    let onAction: (AppAction) -> Void
    
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
    
    var isPlaying: Bool? {
        if let optimisticState = controller.optimisticStates[platform.id] {
            return optimisticState
        }
        return state.isPlaying
    }
    
    var body: some View {
        VStack {
            MediaControlPanel(
                title: platform.name,
                mediaInfo: state.title,
                isPlaying: isPlaying,
                skipInterval: skipInterval,
                onBackward: { onAction(.skipBackward(skipInterval)) },
                onPlayPause: { onAction(.playPauseToggle) },
                onForward: { onAction(.skipForward(skipInterval)) },
                usePlayPauseIcon: usePlayPauseIcon
            )
        }
        .onAppear {
            controller.updateAllStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            controller.updateAllStates()
        }
    }
} 
