import SwiftUI

struct ComputerRowView: View {
    let computer: Connection
    let isConnecting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(computer.name)
                        .font(.headline)
                    Text(computer.host)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let username = computer.lastUsername {
                        Text(username)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if isConnecting {
                    ProgressView()
                }
            }
        }
        .accessibilityLabel("Device")
        .accessibilityValue("\(computer.name) at host  \(computer.host); \(computer.lastUsername != nil ? "saved user: \(computer.lastUsername!)" : "")")
        .disabled(isConnecting)
    }
} 