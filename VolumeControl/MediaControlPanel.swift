import SwiftUI

struct MediaControlPanel: View {
    let title: String
    let mediaInfo: String
    let isPlaying: Bool?  // Optional since VLC doesn't expose state
    let skipInterval: Int
    let onBackward: () -> Void
    let onPlayPause: () -> Void
    let onForward: () -> Void
    let usePlayPauseIcon: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(title)
                    .fontWeight(.bold)
                    .fontWidth(.expanded)
                Text(mediaInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            HStack(spacing: 20) {
                Button("\(skipInterval == 1 ? "Previous track" : "Back \(skipInterval) seconds")", 
                       systemImage: skipInterval == 1 ? "arrowtriangle.backward.fill" : "\(skipInterval).arrow.trianglehead.counterclockwise") {
                    onBackward()
                }
                .styledButton()
                
                Button(action: onPlayPause) {
                    if usePlayPauseIcon {
                        Image(systemName: "playpause.fill")
                    } else if let isPlaying = isPlaying {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .styledButton()
                
                Button("\(skipInterval == 1 ? "Next track" : "Forward \(skipInterval) seconds")", 
                       systemImage: skipInterval == 1 ? "arrowtriangle.forward.fill" : "\(skipInterval).arrow.trianglehead.clockwise") {
                    onForward()
                }
                .styledButton()
            }
        }
    }
} 