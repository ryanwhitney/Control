import SwiftUI

struct ThemePreferenceView: View {
    @StateObject private var preferences = UserPreferences.shared
    @StateObject private var savedConnections = SavedConnections()
    @State private var selectedIndex: Int = 0
    @State private var previewVolume: Float = 0.5

    private static let colors = [
        ("Blue", "blue", Color.blue),
        ("Indigo", "indigo", Color.indigo),
        ("Purple", "purple", Color.purple),
        ("Pink", "pink", Color.pink),
        ("Red", "red", Color.red),
        ("Orange", "orange", Color.orange),
        ("Green", "green", Color.green),
        ("Mint", "mint", Color.mint),
        ("Teal", "teal", Color.teal),
        ("Cyan", "cyan", Color.cyan)
    ]

    // show their an actual saved connection if they have one
    private var defaultComputerInfo: (name: String, host: String, username: String) {
        if let firstSaved = savedConnections.items.first {
            return (
                firstSaved.name ?? "MacBook Pro",
                firstSaved.hostname,
                firstSaved.username ?? "jh"
            )
        }
        return ("JH's MacBook Pro", "johnny-highway-mbp.local", "jh")
    }

    var body: some View {
        let computerInfo = defaultComputerInfo
        VStack {
            VStack(spacing: 0) {
                VStack(spacing: 32) {
                    ComputerRowView(
                        computer: Connection(
                            id: "preview-mac",
                            name: computerInfo.name,
                            host: computerInfo.host,
                            type: .manual,
                            lastUsername: computerInfo.username
                        ),
                        isConnecting: false,
                        action: {}
                    )
                    .padding()
                    .background(.thinMaterial)
                    .cornerRadius(20)
                    VStack(spacing: 20){
                        HStack(spacing: 16) {
                            ForEach(["gobackward.10", "play.fill", "goforward.10"], id: \.self) { symbol in
                                Button(action: {}) {
                                    Image(systemName: symbol)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: symbol == "play.fill" ? 40 : 30, height: symbol == "play.fill" ? 45 : 30)
                                }
                                .buttonStyle(IconButtonStyle())
                            }
                        }
                        HStack(spacing: 0){
                            Button{
                                let newVolume = max(previewVolume - 0.05, 0.0)
                                previewVolume = newVolume
                            } label: {
                                Label("Decrease volume 5%", systemImage: "speaker.minus.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(Color.accentColor)
                                    .padding(10)
                                    .padding(.top, 3)
                            }
                            .frame(width: 44, height: 44)
                            WooglySlider(
                                value: Binding(
                                    get: { Double(previewVolume) },
                                    set: { previewVolume = Float($0) }
                                ),
                                in: 0...1,
                                step: 0.01,
                                onEditingChanged: { _ in }
                            )
                            .accessibilityLabel("Volume Slider")
                            Button{
                                let newVolume = min(previewVolume + 0.05, 1.0)
                                previewVolume = newVolume
                            } label: {
                                Label("Increase volume 5%", systemImage: "speaker.plus.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(Color.accentColor)
                                    .padding(10)
                                    .padding(.top, 3)
                            }
                            .frame(width: 44, height: 44)
                        }
                    }
                    .padding(.top, 4)
                }
                .animation(.spring(), value: preferences.tintColor)
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 24)
                List {
                    Section {
                        ForEach(Self.colors.indices, id: \.self) { index in
                            let (name, value, color) = Self.colors[index]
                            Button {
                                preferences.tintColor = value
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(color)
                                        .frame(width: 16, height: 16)
                                        .padding(.trailing, 4)
                                    Text(name)
                                    Spacer()
                                    if preferences.tintColor == value {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(color)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8)
                .contentMargins(.bottom, 32)
            }
        }
        .background(.black)
    }
}

#Preview {
    ThemePreferenceView()
}
