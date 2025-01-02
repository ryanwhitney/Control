import SwiftUI


struct ThemeSettingsView: View {
    @StateObject private var preferences = UserPreferences.shared

    private let colors = [
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

    var body: some View {
        List {
            Section {
                ForEach(colors, id: \.1) { name, value, color in
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
            } header: {
                Text("App Tint Color")
            }
            Section {
                VStack(spacing: 16) {
                    // Preview Computer Row
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Bokonon's MacBook Pro")
                                .font(.headline)
                                .foregroundStyle(.tint)
                            Text("bokonon-mbp.local")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(.thinMaterial)
                    .cornerRadius(10)

                    // Preview Media Controls
                    HStack(spacing: 16) {
                        Button(action: {}) {
                            Image(systemName: "gobackward.10")
                        }
                        .buttonStyle(CircularButtonStyle())

                        Button(action: {}) {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(CircularButtonStyle())

                        Button(action: {}) {
                            Image(systemName: "goforward.10")
                        }
                        .buttonStyle(CircularButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .background(Color.black)
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .tint(preferences.tintColorValue)

    }
}

#Preview {
    NavigationStack {
        ThemeSettingsView()
    }
}

