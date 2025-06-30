import SwiftUI
import MultiBlur

struct ExperimentalPlatformsView: View {
    @StateObject private var platformRegistry = PlatformRegistry()
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Experimental Apps")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("These may have limited functionality or reliability issues.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                ForEach(platformRegistry.experimentalPlatforms, id: \.id) { platform in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            HStack(spacing: 8) {
                                Text(platform.name)
                                    .font(.headline)

                                Image(systemName: "flask.fill")
                                    .foregroundStyle(.tint)
                                    .font(.subheadline)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { platformRegistry.enabledExperimentalPlatforms.contains(platform.id) },
                                set: { _ in platformRegistry.toggleExperimentalPlatform(platform.id) }
                            ))
                        }

                    }
                    .padding()
                    .background(.ultraThinMaterial.opacity(0.5))
                    .cornerRadius(12)
                    Text(platform.reasonForExperimental)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
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
