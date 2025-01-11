import SwiftUI

struct PlatformControlPanel: View {
    @StateObject private var preferences = UserPreferences.shared
    let title: String
    let mediaInfo: String
    let isPlaying: Bool?
    let actions: [ActionConfig]
    let onAction: (AppAction) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                HStack{
                    Text(title)
                        .fontWeight(.bold)
                        .fontWidth(.expanded)
                    if title.contains("Safari") {
                        Label("Experimental", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                    }
                }
                Text(mediaInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .id(mediaInfo)
            }
            
            HStack(spacing: 16) {
                ForEach(actions) { config in
                    Button(action: { onAction(config.action) }) {
                        if let dynamicIcon = config.dynamicIcon, let isPlaying = isPlaying {
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
    }
} 
