import SwiftUI

struct ThemePreferenceSheet: View {
    @StateObject private var preferences = UserPreferences.shared

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

    var body: some View {
        VStack(spacing:16) {
            Text("Pick a theme color".uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal){
                HStack(spacing: 16) {
                    ForEach(Self.colors.indices, id: \.self) { index in
                        let (_, value, color) = Self.colors[index]
                        Button {
                            preferences.tintColor = value
                        } label: {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: preferences.tintColor == value ? 4 : 0)

                                .background(Circle().fill(color))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Select \(value)")

                    }
                    .foregroundStyle(.primary)
                }
                .padding()
            }
            .scrollIndicators(.hidden)

        }

    }
}

#Preview {
    ThemePreferenceSheet()
}
