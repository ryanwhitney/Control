import SwiftUI
import MultiBlur

struct ExperimentalPlatformsView: View {
    @StateObject private var platformRegistry = PlatformRegistry()
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Experimental Platforms")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("These platforms are experimental and may have limited functionality or reliability issues.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                ForEach(platformRegistry.experimentalPlatforms, id: \.id) { platform in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            HStack(spacing: 8) {
                                Text(platform.name)
                                    .fontWeight(.medium)
                                
                                Image(systemName: "flask.fill")
                                    .foregroundStyle(.tint)
                                    .font(.caption)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { platformRegistry.enabledExperimentalPlatforms.contains(platform.id) },
                                set: { _ in platformRegistry.toggleExperimentalPlatform(platform.id) }
                            ))
                        }
                        
                        Text(platform.reasonForExperimental)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(.ultraThinMaterial.opacity(0.5))
                    .cornerRadius(12)
                }
            }
            
            Spacer()
        }
        .padding()
    }
}


#Preview {
    ExperimentalPlatformsView()
}
