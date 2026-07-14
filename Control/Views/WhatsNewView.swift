import SwiftUI
import MultiBlur

struct WhatsNewView: View {
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onDismiss: () -> Void
    
    /// The sheet only floats as a centered, bordered card in regular-width
    /// presentations (e.g. iPad). On iPhone it's a full-screen sheet, where a
    /// border would look out of place.
    private var isFloatingDialog: Bool {
        horizontalSizeClass == .regular
    }
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                Image("control-2-header")
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
                    
                // Scrollable Content
                ScrollView {
                    Spacer(minLength: 240)
                    VStack(spacing: 16) {
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
                                .accessibilityAddTraits(.isHeader)
                        }
                        .padding(.horizontal)
                        .padding(.top)
                        VStack (alignment: .leading,spacing: 16){
                            Text("In this update, I’ve overhauled how Control talks to your Mac. Commands are now as close to instant as possible.")
                            Text("If the new method doesn't play nicely with your machine, switch to **compatibility mode** in settings.")
                            Text("Also here:").italic()+Text(" minor design touch-ups, bug fixes, and troubleshooting improvements.")
                            Text("Control gets better with your feedback.").bold()+Text(" Thanks for trying the app, and thanks to all who have reached out. Enjoy!")
                            Text("–RW")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                                .fontWidth(.expanded)
                                .fontWeight(.bold)
                        }
                        .padding()
                    }
                    .background{
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.black)
                            .blur(radius: 80)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                    
                }
                .scrollContentBackground(.hidden)
                
                // Fixed Button at Bottom
                VStack{
                    Spacer()
                    BottomButtonPanel{
                        if #available(iOS 26.0, *) {
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
                            .buttonStyle(.glass)
                            .glassEffect(.regular.tint(.green).interactive())                            .tint(.green)
                            .padding(.horizontal)
                            .padding(.vertical, 16)
                        } else {
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
            }
            .background(Color(.black))
            .border(Color(.gray).opacity(isFloatingDialog ? 0.5 : 0), width: 1)
            
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
