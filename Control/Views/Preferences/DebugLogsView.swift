import SwiftUI

struct DebugLogsView: View {
    let isReadOnly: Bool
    @StateObject private var debugLogger = DebugLogger.shared
    @State private var showingShareSheet = false
    @State private var searchText = ""
    
    init(isReadOnly: Bool = false) {
        self.isReadOnly = isReadOnly
    }
    
    var filteredLogs: [DebugLogger.DebugLogEntry] {
        if searchText.isEmpty {
            return debugLogger.logs
        } else {
            return debugLogger.logs.filter { log in
                log.message.localizedCaseInsensitiveContains(searchText) ||
                log.category.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                VStack(spacing: 12) {
                    Toggle("Enable Debug Logging", isOn: Binding(
                        get: { debugLogger.isLoggingEnabled },
                        set: { newValue in
                            debugLogger.isLoggingEnabled = newValue
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: .red))
                    .disabled(isReadOnly)
                    Group{
                        if isReadOnly {
                            Text("To disable logging, go to  Preferences > Support.")
                        } else {
                            Text("Control never logs passwords, hostnames, IP addresses, or info about what you're playing.")
                        }
                        
                        if debugLogger.isLoggingEnabled && !debugLogger.logs.isEmpty {
                            Text("\(debugLogger.logs.count) log entries • Auto-cleanup every 20min or after 24 hours")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                
                if debugLogger.logs.isEmpty {
                    ContentUnavailableView(
                        "No Debug Logs",
                        systemImage: "doc.text",
                        description: Text("Debug logs will appear here as you use the app")
                    )
                } else {
                    List {
                        ForEach(filteredLogs.reversed()) { log in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(log.category)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Capsule())
                                    
                                    Spacer()
                                    
                                    Text(log.formattedTimestamp)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                
                                Text(log.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(nil)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Search logs...")
                }
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showingShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(debugLogger.logs.isEmpty)
                        
                        Menu {
                            Button(role: .destructive) {
                                debugLogger.clearLogs()
                            } label: {
                                Label("Clear All Logs", systemImage: "trash")
                            }
                            .disabled(debugLogger.logs.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: [debugLogger.allLogsText])
        }
    }
    

}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityViewController = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return activityViewController
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    // Add some sample logs for preview
    let logger = DebugLogger.shared
    Task { @MainActor in
        logger.log("Sample SSH connection message", category: "SSH")
        logger.log("Sample connection manager message", category: "Connection")
        logger.log("Sample app controller message", category: "AppController")
        logger.log("Sample view message", category: "ControlView")
    }
    
    return DebugLogsView(isReadOnly: false)
} 
