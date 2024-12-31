import SwiftUI

struct MediaControlView: View {
    let platform: any MediaPlatform
    @Binding var state: MediaState
    let onAction: (MediaAction) -> Void
    
    var body: some View {
        VStack {
            // UI for platform info, subtitles, actions, etc.
        }
    }
} 