import SwiftUI

struct ComputerRowView: View {
    let computer: Connection
    let isConnecting: Bool
    let action: () -> Void

    private var accessibilityDetails: String {
        var parts = [computer.host]
        if let username = computer.lastUsername {
            parts.append("saved user \(username)")
        }
        if isConnecting {
            parts.append("connecting")
        }
        return parts.joined(separator: ", ")
    }

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
        // The name is the label so VoiceOver leads with it and Voice Control users
        // can say "Tap Ryan's MacBook Pro"; host and saved user ride in the value.
        .accessibilityLabel(computer.name)
        .accessibilityValue(accessibilityDetails)
        .accessibilityInputLabels([computer.name])
        .disabled(isConnecting)
    }
}

#Preview("Normal State") {
    List {
        ComputerRowView(
            computer: Connection(
                id: "ryan-macbook",
                name: "Ryan's MacBook Pro",
                host: "ryan-macbook.local",
                type: .manual,
                lastUsername: "ryan"
            ),
            isConnecting: false,
            action: {}
        )
        
        ComputerRowView(
            computer: Connection(
                id: "mac-studio",
                name: "Mac Studio",
                host: "192.168.1.100",
                type: .manual,
                lastUsername: nil
            ),
            isConnecting: false,
            action: {}
        )
    }
}

#Preview("Connecting State") {
    List {
        ComputerRowView(
            computer: Connection(
                id: "ryan-macbook",
                name: "Ryan's MacBook Pro",
                host: "ryan-macbook.local",
                type: .manual,
                lastUsername: "ryan"
            ),
            isConnecting: true,
            action: {}
        )
    }
} 