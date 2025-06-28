import SwiftUI

struct DebugLogsView: View {
    @StateObject private var debugLogger = DebugLogger.shared
    @State private var showingShareSheet = false
    @State private var showingPrivacyAlert = false
    @State private var searchText = ""
    
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
                // Privacy controls section
                VStack(spacing: 12) {
                    Toggle("Enable Debug Logging", isOn: Binding(
                        get: { debugLogger.isLoggingEnabled },
                        set: { newValue in
                            if newValue && !debugLogger.isLoggingEnabled {
                                showingPrivacyAlert = true
                            } else {
                                debugLogger.isLoggingEnabled = newValue
                            }
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: .red))
                    
                    if !debugLogger.isLoggingEnabled {
                        Text("Enable logging to capture debug information. No sensitive data like passwords will be saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                
                if !debugLogger.isLoggingEnabled {
                    ContentUnavailableView(
                        "Debug Logging Disabled",
                        systemImage: "eye.slash",
                        description: Text("Enable debug logging above to capture troubleshooting information")
                    )
                } else if debugLogger.logs.isEmpty {
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
                        .disabled(!debugLogger.isLoggingEnabled || debugLogger.logs.isEmpty)
                        
                        Menu {
                            Button(role: .destructive) {
                                debugLogger.clearLogs()
                            } label: {
                                Label("Clear Logs", systemImage: "trash")
                            }
                            .disabled(!debugLogger.isLoggingEnabled || debugLogger.logs.isEmpty)
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
        .alert("Enable Debug Logging?", isPresented: $showingPrivacyAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Enable") {
                debugLogger.isLoggingEnabled = true
            }
        } message: {
            Text("Debug logs help troubleshoot connection issues. Control protects your privacy by:\n\n• Only logging if enabled\n• Never logging sensitive data like passwords & movie/song titles\n• Keeping logs local on your device\n• Allowing you to clear logs anytime")
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
    
    return DebugLogsView()
} 
