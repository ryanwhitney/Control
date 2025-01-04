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
                Text(title)
                    .fontWeight(.bold)
                    .fontWidth(.expanded)
                Text(mediaInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .id(mediaInfo)
            }
            
            HStack(spacing: 10) {
                ForEach(actions) { config in
                    Button(action: { onAction(config.action) }) {
                        if let dynamicIcon = config.dynamicIcon, let isPlaying = isPlaying {
                            Image(systemName: dynamicIcon(isPlaying))
                        } else {
                            Label(config.action.label, systemImage: config.staticIcon)
                        }
                    }
                    .buttonStyle(IconButtonStyle())
                }
            }
        }
    }
} 
