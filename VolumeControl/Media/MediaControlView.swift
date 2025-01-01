import SwiftUI

struct MediaControlView: View {
    let platform: any AppPlatform
    @Binding var state: AppState
    let onAction: (AppAction) -> Void
    
    var body: some View {
        VStack {
            // UI for platform info, subtitles, actions, etc.
        }
    }
} 
