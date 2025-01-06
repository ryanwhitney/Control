import SwiftUI
import MultiBlur

struct ChooseAppsView: View {
    let hostname: String
    let displayName: String
    let sshClient: SSHClientProtocol
    let onComplete: (Set<String>) -> Void

    @State private var headerHeight: CGFloat = 0
    @State private var showAppList: Bool = false
    @State private var selectedPlatforms: Set<String> = Set(PlatformRegistry.allPlatforms.map { $0.id })

    var body: some View {
        ZStack(alignment: .top) {
            /// ScrollView
            ScrollView {
                HStack{EmptyView()}.frame(height: headerHeight)
                VStack(spacing: 8) {
                    ForEach(PlatformRegistry.allPlatforms, id: \.id) { platform in
                        HStack{
                            Toggle(isOn: Binding(
                                get: { selectedPlatforms.contains(platform.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedPlatforms.insert(platform.id)
                                    } else {
                                        selectedPlatforms.remove(platform.id)
                                    }
                                }
                            )) {
                                Text(platform.name)
                                    .padding()
                            }
                            .padding(.trailing)
                            .foregroundStyle(.primary)
                        }
                        .background(.ultraThinMaterial.opacity(0.5))
                        .cornerRadius(14)
                        .onTapGesture {
                            if selectedPlatforms.contains(platform.id) {
                                selectedPlatforms.remove(platform.id)
                            } else {
                                selectedPlatforms.insert(platform.id)
                            }
                        }
                        .opacity(selectedPlatforms.contains(platform.id) ? 1 : 0.5)
                        .animation(.spring(), value: selectedPlatforms)
                        .accessibilityAddTraits(.isToggle)
                        .accessibilityLabel("\(platform.name), \(selectedPlatforms.contains(platform.id) ? "enabled" : "disabled")")
                        .accessibilityHint("Tap to \(selectedPlatforms.contains(platform.id) ? "disable" : "enable") this platform.")
                    }
                }
                .padding()
            }
        /// Header
            VStack(spacing: 8) {
                Image(systemName: "macbook.and.iphone")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 40)
                    .padding(0)
                    .foregroundStyle(.tint, .quaternary)
                    .padding(.bottom, -20)
                Text("Which apps would you like to control?")
                    .font(.title2)
                    .bold()
                    .padding(.horizontal)
                    .padding(.top)
                Text("You can change these anytime.")
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            .frame(maxWidth:.infinity)
            .multilineTextAlignment(.center)
            .background(GeometryReader {
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -30)
                    .preference(key: headerSizePreferenceKey.self, value: $0.size.height)
            })
            .onPreferenceChange(headerSizePreferenceKey.self) { value in
                self.headerHeight = value
                print("Header Height: \(headerHeight)")
            }
            /// Bottom panel
            VStack{
                Spacer()
                BottomButtonPanel{
                    Button(action: {
                        onComplete(selectedPlatforms)
                    }) {
                        Text("Continue")
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .tint(.accentColor)
                            .foregroundStyle(.tint)
                            .fontWeight(.bold)
                            .multiblur([(10,0.25), (20,0.35), (50,0.5),  (100,0.5)])
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding()
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .frame(maxWidth: .infinity)
                    .disabled(selectedPlatforms.isEmpty)
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
    }
}


struct headerSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

#Preview {
    let client = SSHClient()
    client.connect(host: "rwhitney-mac.local", username: "ryan", password: "") { _ in }

    return NavigationStack {
        ChooseAppsView(
            hostname: "rwhitney-mac.local",
            displayName: "Ryan's Mac",
            sshClient: client,
            onComplete: { _ in }
        )
    }
}
