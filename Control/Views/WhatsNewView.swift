import SwiftUI
import MultiBlur

struct WhatsNewView: View {
    @StateObject private var preferences = UserPreferences.shared
    let onDismiss: () -> Void
    
    private let newFeatures = [
        WhatsNewFeature(
            icon: "flask.fill",
            iconColor: .indigo,
            title: "Experimental App Controls",
            description: "Controls for Safari can now be enabled in Preferences."
        ),
        WhatsNewFeature(
            icon: "square.fill.on.square.fill",
            iconColor: .blue,
            title: "Manage App Controls",
            description: "Update which apps are enabled directly from the control screen."
        ),
        WhatsNewFeature(
            icon: "wifi",
            iconColor: .green,
            title: "Improved Connectivity",
            description: "Briefly switching apps no longer closes your connection."
        )
    ]
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // Scrollable Content
                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 16) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 40))
                                .foregroundStyle(.tint)
                                .padding(.top, 20)
                                .multiblur([(10,0.25), (50,0.35)])
                            VStack(spacing:8){
                                Text("What's New")
                                    .font(.title)
                                    .fontWeight(.bold)
                                Text("Control now provides…more control.")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding()
                        
                        // Features
                        VStack(spacing: 16) {
                            ForEach(newFeatures) { feature in
                                FeatureCard(feature: feature)
                            }
                            Text("VERSION 1.1")
                                .font(.footnote)
                                .tracking(1)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 10)
                        }
                        .padding(.horizontal)
                    }
                }
                .scrollContentBackground(.hidden)

                // Fixed Button at Bottom
                VStack{
                    Spacer()
                    BottomButtonPanel{
                        Button {
                            preferences.markWhatsNewAsSeen()
                            onDismiss()
                        } label: {
                            HStack {
                                Text("Continue")
                                    .font(.headline)
                                    .multiblur([(10,0.25), (50,0.35)])
                            }
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                        }
                        .cornerRadius(12)
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                        .padding(.horizontal)
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .presentationBackground(.black)
        .tint(preferences.tintColorValue)
    }
}

struct FeatureCard: View {
    let feature: WhatsNewFeature
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(feature.iconColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Image(systemName: feature.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(feature.iconColor)
                    .multiblur([(10,0.25), (50,0.35)])
            }
            
            // Content
            VStack(alignment: .leading, spacing: 6) {
                Text(feature.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text(feature.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(feature.title). \(feature.description)")
    }
}

struct WhatsNewFeature: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
}

#Preview {
    WhatsNewView(onDismiss: {})
} 
