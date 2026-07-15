import SwiftUI

/// Shown once when Fast (streaming) mode connects but its stream never responds,
/// after the app has already auto-switched that session to Compatibility mode.
/// The toggle lets the user make Compatibility the persisted global default; if
/// left off, the switch is only for this session (Fast is retried next launch).
struct CompatibilityFallbackNotice: View {
    let displayName: String
    @ObservedObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss

    /// Reflects and drives the persisted global default. On → save Compatibility;
    /// off → restore Fast. (We only reach this sheet from Fast, so global was Fast.)
    private var alwaysUseCompatibility: Binding<Bool> {
        Binding(
            get: { preferences.connectionMethod == .compatibility },
            set: { preferences.connectionMethod = $0 ? .compatibility : .streaming }
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(preferences.tintColorValue)
                .padding(.top, 28)
                .accessibilityHidden(true)

            Text("Switched to Compatibility Mode")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("Due to connection issues, Control is switching to Compatibility mode. It’s a little slower, but more reliable for communicating with some Macs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Always use Compatibility mode", isOn: alwaysUseCompatibility)
                .padding(.horizontal, 4)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Spacer()
            Button {
                dismiss()
            } label: {
                HStack {
                    Text("OK")
                        .multiblur([(10,0.25), (50,0.35)])
                }
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .glassPillLabel()
                .fontWeight(.bold)
            }
            .glassPillButtonStyle(tint: .accentColor)
            .frame(maxWidth: .infinity)

        }
        .padding(24)
        .tint(preferences.tintColorValue)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CompatibilityFallbackNotice(displayName: "Ryan’s Mac")
        }
}
