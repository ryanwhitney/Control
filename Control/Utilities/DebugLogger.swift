import Foundation
import SwiftUI

@MainActor
class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published private(set) var logs: [DebugLogEntry] = []
    @Published var isLoggingEnabled: Bool = false
    private let maxLogs = 1000 // Keep last 1000 entries
    
    struct DebugLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let category: String
        
        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            formatter.dateStyle = .none
            return formatter.string(from: timestamp)
        }
        
        var formattedEntry: String {
            "[\(formattedTimestamp)] \(category): \(message)"
        }
    }
    
    private init() {}
    
    func log(_ message: String, category: String = "General") {
        // Always print to console for development, but sanitize sensitive data
        let sanitizedMessage = sanitizeMessage(message)
        print("[\(category)] \(sanitizedMessage)")
        
        // Only save to user-visible logs if enabled
        guard isLoggingEnabled else { return }
        
        let entry = DebugLogEntry(
            timestamp: Date(),
            message: sanitizedMessage,
            category: category
        )
        
        logs.append(entry)
        
        // Keep only the most recent logs
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }
    
    private func sanitizeMessage(_ message: String) -> String {
        var sanitized = message
        
        // Remove/sanitize sensitive patterns
        // Password patterns (case insensitive)
        let passwordPatterns = [
            #"password:\s*[^\s]+"#,
            #"Password:\s*[^\s]+"#,
            #"PASSWORD:\s*[^\s]+"#,
            #"pass:\s*[^\s]+"#,
            #"pwd:\s*[^\s]+"#
        ]
        
        for pattern in passwordPatterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "password: [REDACTED]",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        // Sanitize long strings that might be passwords (8+ chars with no spaces)
        let longStringPattern = #"\b[^\s]{8,}\b"#
        if message.lowercased().contains("password") {
            sanitized = sanitized.replacingOccurrences(
                of: longStringPattern,
                with: "[REDACTED]",
                options: .regularExpression
            )
        }
        
        // Sanitize media titles and subtitles from command outputs
        if sanitized.contains("Full output:") {
            sanitized = sanitizeMediaContent(sanitized)
        }
        
        // Also sanitize any other potential media content patterns
        sanitized = sanitizeGeneralMediaContent(sanitized)
        
        return sanitized
    }
    
    private func sanitizeMediaContent(_ message: String) -> String {
        // Extract the output part after "Full output: "
        guard let outputRange = message.range(of: "Full output: ") else {
            return message
        }
        
        let prefix = String(message[..<outputRange.upperBound])
        let output = String(message[outputRange.upperBound...])
        
        // Look for AppleScript output format: "title|||subtitle|||state|||playing"
        let components = output.components(separatedBy: "|||")
        
        if components.count >= 2 {
            var sanitizedComponents = components
            
            // System messages that should not be redacted
            let systemMessages = [
                "not running", "nothing playing", "loading...", "permissions required",
                "no media playing", "error:", "no windows open", "no media found",
                "stopped", "", "   ", "false", "true", "playing", "paused"
            ]
            
            // Redact title (first component) if it's not a system message
            let title = components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isSystemMessage = systemMessages.contains { systemMsg in
                title.contains(systemMsg) || systemMsg.contains(title)
            }
            
            if !isSystemMessage && components[0].trimmingCharacters(in: .whitespacesAndNewlines).count > 3 {
                let originalTitle = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                sanitizedComponents[0] = String(originalTitle.prefix(3)) + "***"
            }
            
            // Redact subtitle (second component) if it's not empty/spaces and looks like media info
            if components.count >= 2 {
                let subtitle = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if subtitle.count > 3 && !subtitle.isEmpty && subtitle != "   " {
                    sanitizedComponents[1] = String(subtitle.prefix(3)) + "***"
                }
            }
            
            return prefix + sanitizedComponents.joined(separator: "|||")
        }
        
        return message
    }
    
    private func sanitizeGeneralMediaContent(_ message: String) -> String {
        var sanitized = message
        
        // Don't sanitize system/error messages
        let systemKeywords = [
            "not running", "nothing playing", "loading", "permissions required",
            "no media", "error", "failed", "connection", "timeout", "authentication"
        ]
        
        let messageText = message.lowercased()
        let containsSystemKeyword = systemKeywords.contains { keyword in
            messageText.contains(keyword)
        }
        
        if containsSystemKeyword {
            return message
        }
        
        // Look for standalone media info patterns (not in Full output format)
        // Pattern: anything|||anything format that might be media content
        if message.contains("|||") && !message.contains("Full output:") {
            let components = message.components(separatedBy: "|||")
            
            if components.count >= 2 {
                var sanitizedComponents = components
                
                // Check first component for potential media title
                if components[0].trimmingCharacters(in: .whitespacesAndNewlines).count > 3 {
                    let title = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    // Only redact if it doesn't look like a system message
                    if !title.lowercased().contains("stopped") && 
                       !title.lowercased().contains("false") &&
                       !title.lowercased().contains("true") &&
                       !title.isEmpty {
                        sanitizedComponents[0] = String(title.prefix(3)) + "***"
                    }
                }
                
                // Check second component for potential artist/subtitle
                if components.count >= 2 {
                    let subtitle = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if subtitle.count > 3 && !subtitle.isEmpty && subtitle != "   " {
                        sanitizedComponents[1] = String(subtitle.prefix(3)) + "***"
                    }
                }
                
                sanitized = sanitizedComponents.joined(separator: "|||")
            }
        }
        
        return sanitized
    }
    
    func clearLogs() {
        logs.removeAll()
    }
    
    var allLogsText: String {
        logs.map { $0.formattedEntry }.joined(separator: "\n")
    }
    
    var recentLogsText: String {
        let recentLogs = logs.suffix(50) // Last 50 entries
        return recentLogs.map { $0.formattedEntry }.joined(separator: "\n")
    }
}

// Convenience functions to replace print statements
func debugLog(_ message: String, category: String = "General") {
    Task { @MainActor in
        DebugLogger.shared.log(message, category: category)
    }
}

func sshLog(_ message: String) {
    debugLog(message, category: "SSH")
}

func connectionLog(_ message: String) {
    debugLog(message, category: "Connection")
}

func appControllerLog(_ message: String) {
    debugLog(message, category: "AppController")
}

func viewLog(_ message: String, view: String) {
    debugLog(message, category: view)
}

// Safe logging functions that automatically sanitize sensitive data
func safeConnectionLog(host: String, username: String, action: String) {
    let safeHost = String(host.prefix(10)) + (host.count > 10 ? "***" : "")
    let safeUsername = String(username.prefix(3)) + (username.count > 3 ? "***" : "")
    connectionLog("\(action) - Host: \(safeHost), User: \(safeUsername)")
}

func safeCommandLog(_ command: String, description: String? = nil) {
    let safeCommand = command.count > 50 ? String(command.prefix(50)) + "..." : command
    if let description = description {
        appControllerLog("Command: \(description) (\(safeCommand.count) chars)")
    } else {
        appControllerLog("Command executed (\(safeCommand.count) chars)")
    }
} 