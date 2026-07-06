import SwiftUI

struct ConnectionsListView: View {
    @EnvironmentObject private var viewModel: ConnectionsViewModel

    /// True once the rows are tall enough to fill the viewport, meaning the help
    /// button should ride at the bottom of the scrollable content rather than float.
    @State private var contentFillsViewport = false

    private var statusText: String {
        if viewModel.isSearching {
            return "Searching…"
        } else {
            return viewModel.networkComputers.isEmpty ? "No connections found" : ""
        }
    }

    var body: some View {
        ZStack {
            list

            // Short list: keep the plain help button floating, pinned to the bottom.
            if !contentFillsViewport {
                HelpButtonView(hasConnections: true) {
                    viewModel.activePopover = .help
                }
            }
        }
    }

    private var list: some View {
        List {
            Section(header: Text("On Your Network".capitalized)) {
                ForEach(viewModel.networkComputers) { computer in
                    ComputerRowView(
                        computer: computer,
                        isConnecting: viewModel.connectingComputer?.id == computer.id
                    ) {
                        viewModel.selectComputer(computer)
                    }
                    .accessibilityHint(viewModel.connectingComputer?.id == computer.id ? "Currently connecting" : "Tap to connect")
                    .accessibilityAddTraits(viewModel.connectingComputer?.id == computer.id ? .updatesFrequently : [])
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }

                if viewModel.networkComputers.isEmpty || viewModel.isSearching {
                    HStack {
                        Text(viewModel.showStatusRow ? statusText : "")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Spacer()
                        if viewModel.showProgressIndicator {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        )
                        .combined(with: .opacity)
                    )
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
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
            }
            .opacity(viewModel.savedComputers.isEmpty ? 0 : 1)
            .accessibilityLabel("Recent connections")

            // Tall list: the help button becomes an inline footer, revealed when
            // the user scrolls to the bottom instead of floating over the rows.
            if contentFillsViewport {
                Section {
                    HelpPromptButton { viewModel.activePopover = .help }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .modifier(ContentOverflowReporter(fillsViewport: $contentFillsViewport))
        .animation(.spring(duration: 0.3), value: viewModel.networkComputers.map(\.id))
        .animation(.spring(duration: 0.3), value: viewModel.savedComputers.map(\.id))
        .animation(.spring(duration: 0.3), value: viewModel.isSearching)
        .animation(.spring(duration: 0.2), value: viewModel.showProgressIndicator)
        .animation(.spring(duration: 0.2), value: viewModel.showStatusRow)
    }
}

/// Reports whether a scrollable view's content overflows its viewport, so callers
/// can switch a floating footer into an inline one. No-op before iOS 18.
private struct ContentOverflowReporter: ViewModifier {
    @Binding var fillsViewport: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.containerSize.height + 1
            } action: { _, overflows in
                fillsViewport = overflows
            }
        } else {
            content
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
