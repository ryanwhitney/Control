import SwiftUI

struct ThemePreferenceSheet: View {
    @StateObject private var preferences = UserPreferences.shared

    var body: some View {
        VStack(spacing:16) {
            Text("Pick a theme color".uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal){
                HStack(spacing: 16) {
                    ForEach(UserPreferences.themeColors.indices, id: \.self) { index in
                        let (name, value, color) = UserPreferences.themeColors[index]
                        Button {
                            preferences.tintColor = value
                        } label: {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: preferences.tintColor == value ? 4 : 0)

                                .background(Circle().fill(color))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(preferences.tintColor == value ? [.isSelected] : [])

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
