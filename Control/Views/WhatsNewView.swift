import SwiftUI
import MultiBlur

struct WhatsNewView: View {
    @StateObject private var preferences = UserPreferences.shared
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                Image("control-2-header")
                    .resizable()
                    .scaledToFit()
                // Scrollable Content
                ScrollView {
                    VStack(spacing: 16) {
                        // Header
                        Spacer(minLength: 260)
                        VStack(spacing: 0) {
                            Text("Version 2.0.0")
                                .font(.subheadline)
                                .kerning(2)
                                .foregroundStyle(.green)
                                .fontDesign(.monospaced)
                            
                            Text("Control faster.")
                                .font(.largeTitle)
                                .fontWidth(.expanded)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .fontWeight(.bold)
                        }
                        .padding(.horizontal)
                        .padding(.top)
                        .padding(.bottom, 6)
                        VStack (alignment: .leading,spacing: 16){
                            Text("In this update, I’ve overhauled how Control talks to your Mac, Commands are now close to instant where possible. (Some apps don't support being controlled directly, and others are slow to responond.")
                            Text("If the new methods don’t play nicely with your machine, switch to **compatibility mode** in settings.")
                            Text("Enjoy!")
                        }
                        .padding(.horizontal)
                    }
                    .padding(.horizontal)
                
                }
                .background(Color(.black))
                .border(Color(.gray).opacity(0.5), width: 1)
                .scrollContentBackground(.hidden)

                // Fixed Button at Bottom
                VStack{
                    Spacer()
                    BottomButtonPanel{
                        if #available(iOS 26.0, *) {
                            Button {
                                //                            preferences.markWhatsNewAsSeen()
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
                            .buttonStyle(.glass)
                            .glassEffect(.regular.tint(.green).interactive())                            .tint(.green)
                            .padding(.horizontal)
                            .padding(.vertical, 16)
                        } else {
                            Button {
                                //                            preferences.markWhatsNewAsSeen()
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
            }
            .navigationBarHidden(true)
        }
        .presentationBackground(.black)
        .tint(preferences.tintColorValue)
    }
}

struct FeatureCard: View {
    let feature: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(feature)
                .font(.headline)
                .fontWeight(.semibold)
        }
        .padding()
        .cornerRadius(3)
        .accessibilityElement(children: .combine)
        .glassEffectOrFallback{RoundedRectangle(cornerRadius: 3)
                .fill(.ultraThinMaterial)
        }
        
    }
}


#Preview {
    WhatsNewView(onDismiss: {})
}
