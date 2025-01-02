import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ThemeSettingsView()
                    } label: {
                        HStack {
                            Image(systemName: "theatermask.and.paintbrush.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.primary, .secondary)
                                .frame(width: 28, height: 28)
                                .background(UserPreferences.shared.tintColorValue)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            
                            Text("Theme")
                        }
                    }
                }
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    PreferencesView()
} 
