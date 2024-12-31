import SwiftUI

struct VolumeSlider: View {
    @Binding var volume: Float
    let onChanged: (Float) -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            Slider(value: $volume) { _ in
                onChanged(volume)
            }
            Image(systemName: "speaker.wave.3.fill")
        }
        .padding()
    }
} 