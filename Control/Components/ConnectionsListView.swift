import SwiftUI

struct ConnectionsListView: View {
    @EnvironmentObject private var viewModel: ConnectionsViewModel

    var body: some View {
        List {
            Section(header: Text("On Your Network".capitalized)) {
                if viewModel.networkComputers.isEmpty && viewModel.isSearching {
                    HStack {
                        Text("Scanning...")
                            .foregroundColor(.secondary)
                        Spacer()
                        ProgressView()
                    }
                    .accessibilityLabel("Scanning for devices")
                } else if viewModel.networkComputers.isEmpty {
                    Text("No connections found")
                        .foregroundColor(.secondary)
                }

                ForEach(viewModel.networkComputers) { computer in
                    ComputerRowView(
                        computer: computer,
                        isConnecting: viewModel.connectingComputer?.id == computer.id
                    ) {
                        viewModel.selectComputer(computer)
                    }
                    .accessibilityHint(viewModel.connectingComputer?.id == computer.id ? "Currently connecting" : "Tap to connect")
                    .accessibilityAddTraits(viewModel.connectingComputer?.id == computer.id ? .updatesFrequently : [])
                }

                if !viewModel.networkComputers.isEmpty && viewModel.isSearching {
                    HStack {
                        Text("Searching for others…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        ProgressView()
                    }
                    .accessibilityLabel("Scanning for additional devices")
                }
            }
            Section(header: Text("Recent".capitalized)) {
                ForEach(viewModel.savedComputers) { computer in
                    ComputerRowView(
                        computer: computer,
                        isConnecting: viewModel.connectingComputer?.id == computer.id
                    ) {
                        viewModel.selectComputer(computer)
                    }
                    .accessibilityHint(viewModel.connectingComputer?.id == computer.id ? "Currently connecting" : "Tap to connect")
                    .accessibilityAddTraits(viewModel.connectingComputer?.id == computer.id ? .updatesFrequently : [])
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            viewModel.deleteConnection(hostname: computer.host)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityLabel("Delete \(computer.name)")
                        .tint(.red)

                        Button {
                            viewModel.editConnection(computer)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .accessibilityLabel("Edit \(computer.name)")
                        .tint(.accentColor)
                    }
                }
            }
            .opacity(viewModel.savedComputers.isEmpty ? 0 : 1)
            .accessibilityLabel("Recent connections")
        }
    }
}

#Preview("With Connections") {
    NavigationView {
        List {
            Section(header: Text("On Your Network".capitalized)) {
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
                
                ComputerRowView(
                    computer: Connection(
                        id: "mac-studio", 
                        name: "Mac Studio",
                        host: "mac-studio.local",
                        type: .manual,
                        lastUsername: nil
                    ),
                    isConnecting: false,
                    action: {}
                )
            }
            
            Section(header: Text("Recent".capitalized)) {
                ComputerRowView(
                    computer: Connection(
                        id: "work-mac",
                        name: "Work iMac",
                        host: "192.168.1.100",
                        type: .manual,
                        lastUsername: "work"
                    ),
                    isConnecting: false,
                    action: {}
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        // Mock delete action
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)

                    Button {
                        // Mock edit action
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.accentColor)
                }
            }
        }
    }
}

#Preview("Empty State") {
    NavigationView {
        List {
            Section(header: Text("On Your Network".capitalized)) {
                Text("No connections found")
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Recent".capitalized)) {
                // Empty section
            }
            .opacity(0)
        }
    }
}
