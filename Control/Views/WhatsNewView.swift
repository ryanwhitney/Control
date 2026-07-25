import SwiftUI
import MultiBlur

struct WhatsNewView: View {
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var bottomPanelHeight: CGFloat = 0
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
                Image("control-2-1-header")
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
                    
                // Scrollable Content
                ScrollView {
                    Spacer(minLength: 40)
                    VStack(spacing: 16) {
                        Image("keypad")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240, alignment: .center)
                            .accessibilityHidden(true)
                        VStack(spacing: 6) {
                            Text("Version 2.1.0")
                                .font(.subheadline)
                                .kerning(2)
                                .foregroundStyle(.green)
                                .fontDesign(.monospaced)
                            
                            Text("Control anything.")
                                .font(.largeTitle)
                                .fontWidth(.expanded)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .fontWeight(.bold)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .padding(.top)
                        VStack (alignment: .leading,spacing: 16){
                            Text("Introducing a new set of controls that works with any app on your Mac: **Keyboard**.")
                            Text("The same as hitting a key on your keyboard: the active app gets the key press.")
                            Text("Customizable, with support for shortcuts.")
                            Text("Enable it on new connections or anytime under the ") +
                            Text.withSymbolPrefixes(
                                symbols: [Text.InlineSymbol(name: "ellipsis.circle.fill", accessibilityLabel: "menu")],
                                text: "menu on the controls screen."
                            )
                            Text("–RW")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                                .fontWidth(.expanded)
                                .fontWeight(.bold)
                        }
                    }
                    .background{
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.black)
                            .blur(radius: 80)
                    }
                    .padding(.horizontal)
                    // Clearance for the floating Continue panel, measured live
                    // so it stays right when Dynamic Type grows the button.
                    .padding(.bottom, bottomPanelHeight + 12)

                }
                .scrollContentBackground(.hidden)
                
                // Fixed Button at Bottom
                VStack{
                    Spacer()
                    BottomButtonPanel(height: $bottomPanelHeight){
                        if #available(iOS 26.0, *) {
                            Button {
//                                preferences.markWhatsNewAsSeen()
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
//                                preferences.markWhatsNewAsSeen()
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
