import SwiftUI

struct ThemeSettingsView: View {
    @StateObject private var preferences = UserPreferences.shared
//    @StateObject private var savedConnections = SavedConnections()
//    @State private var previewComputer: (name: String, host: String)?
    @State private var selectedIndex: Int = 0

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
//
//    private var defaultComputerInfo: (name: String, host: String) {
//        if let firstSaved = savedConnections.items.first {
//            return (firstSaved.name ?? "Unknown Device", firstSaved.hostname)
//        }
//        return ("JH's MacBook Pro", "johnny-highway-mbp.local")
//    }

    var body: some View {
//        let computerInfo = defaultComputerInfo
        VStack {
            ZStack {


                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("JH's MacBook Pro")
                                .font(.headline)
                                .foregroundStyle(Self.colors[selectedIndex].2)
                            Text("johnny-highway-mbp.local")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        Spacer()
                    }
                    .padding()
                    .background(.thinMaterial)
                    .cornerRadius(12)

                    HStack(spacing: 16) {
                        ForEach(["gobackward.10", "play.fill", "goforward.10"], id: \.self) { symbol in
                            Button(action: {}) {
                                Image(systemName: symbol)
                            }
                            .buttonStyle(IconButtonStyle())
                            .accentColor(Self.colors[selectedIndex].2)
                        }
                    }
                    HStack(spacing: 16) {
                        ForEach(["-5", "-1", "+1", "+5"], id: \.self) { text in
                            Button(action: {}) {
                                Text(text)
                            }
                            .buttonStyle(CircularButtonStyle())
                            .accentColor(Self.colors[selectedIndex].2)
                        }
                    }
                }
                .animation(.spring(), value: selectedIndex)
                .padding()
                .cornerRadius(12)
                .padding()
                .background(.black)

                TabView(selection: $selectedIndex) {
                    ForEach(Self.colors.indices, id: \.self) { index in
                        let (name, value, color) = Self.colors[index]
                        VStack {
                            Text(name)
                                .font(.title2.bold())
                                .padding()
                            Button(action: {
                                preferences.tintColor = value
                            }) {
                                Text("Set as theme color")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(color)
                        }
                        .padding()
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            }
        }
        .background(.black)
    }
}

#Preview {
    ThemeSettingsView()
}
