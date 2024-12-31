import SwiftUI

struct MediaControl: View {
    let platform: any MediaPlatform
    @Binding var state: MediaState
    @EnvironmentObject var controller: MediaController
    let onAction: (MediaAction) -> Void
    
    var skipInterval: Int {
        switch platform {
        case is MusicPlatform: return 1
        case is QuickTimePlatform: return 5
        default: return 10
        }
    }
    
    var usePlayPauseIcon: Bool {
        switch platform {
        case is VLCPlatform: return true
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