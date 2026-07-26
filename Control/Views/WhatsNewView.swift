import SwiftUI
import MultiBlur

struct WhatsNewView: View {
    @StateObject private var preferences = UserPreferences.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var bottomPanelHeight: CGFloat = 0
    /// Gates the line about turning Keyboard on from an existing connection —
    /// there's nowhere to follow it to without one.
    let hasSavedConnections: Bool
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
                    Spacer(minLength: 36)
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
                        .padding(.top, 6)
                        VStack (alignment: .leading,spacing: 16){
                            Text("Introducing ") + Text("**Keyboard** controls") + Text(":")
                            Text("A new control pane that works the same as pressing keys on your actual keyboard.")
                            
                            Text("That means Control now works with nearly ")+Text("**any video**").fontWidth(.init(0.05)).foregroundStyle(.tint) + Text(",  ")+Text("**any website**").fontWidth(.init(0.05)).foregroundStyle(.tint) + Text(", and ")+Text("**any app**").fontWidth(.init(0.05)).foregroundStyle(.tint) + Text(".")
                            
                            Text("Customizable, with support for shortcuts. ")
                            if hasSavedConnections {
                                Text("Enable it via “Manage Apps” on the ")
                                + Text(Image(systemName: "ellipsis.circle.fill")).accessibilityLabel("More")
                                + Text(" menu on any existing app control screen.")
                            }
                            Text("I hope you find it useful. Reach out anytime.")
                            Text("–RW")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                                .fontWidth(.expanded)
                                .fontWeight(.bold)
                        }
                        .padding(.horizontal, 6)
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
        .themeTint(preferences.tintColorValue)
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


#Preview("Existing user") {
    WhatsNewView(hasSavedConnections: true, onDismiss: {})
}

#Preview("First launch") {
    WhatsNewView(hasSavedConnections: false, onDismiss: {})
}
