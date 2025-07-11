import Foundation
import SwiftUI

@MainActor
class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published private(set) var logs: [DebugLogEntry] = []
    @Published var isLoggingEnabled: Bool = false
    private let maxLogs = 1000
    private let maxAgeHours: Double = 24 
    private var lastCleanupTime = Date()
    
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
    
    private init() {
        // Perform initial cleanup on app start
        Task { @MainActor in
            self.performCleanup()
        }
    }
    
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
        
        // Enforce max line count when adding
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
        
        // Periodic cleanup based on log age
        let now = Date()
        if now.timeIntervalSince(lastCleanupTime) > 1200 { // 20min
            performCleanup()
            lastCleanupTime = now
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
        
        // Sanitize network-related sensitive information
        sanitized = sanitizeNetworkInfo(sanitized)
        
        // Sanitize media titles and subtitles from command outputs
        if sanitized.contains("Full output:") {
            sanitized = sanitizeMediaContent(sanitized)
        }
        
        // Also sanitize any other potential media content patterns
        sanitized = sanitizeGeneralMediaContent(sanitized)
        
        return sanitized
    }
    
    private func sanitizeNetworkInfo(_ message: String) -> String {
        var sanitized = message
        
        // Helper function to perform regex replacement with NSRegularExpression
        func regexReplace(pattern: String, in text: String, replacer: (String) -> String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return text
            }
            let range = NSRange(location: 0, length: text.utf16.count)
            let matches = regex.matches(in: text, options: [], range: range)
            
            var result = text
            var offset = 0
            
            for match in matches {
                let matchRange = match.range
                let adjustedRange = NSRange(location: matchRange.location + offset, length: matchRange.length)
                
                if let swiftRange = Range(adjustedRange, in: result) {
                    let matchedText = String(result[swiftRange])
                    let replacement = replacer(matchedText)
                    result = result.replacingCharacters(in: swiftRange, with: replacement)
                    offset += replacement.count - matchedText.count
                }
            }
            return result
        }
        
        // Redact hostnames (keep first 3 characters)
        sanitized = regexReplace(pattern: #"[a-zA-Z0-9-]+\.local"#, in: sanitized) { match in
            let prefix = String(match.prefix(3))
            return "\(prefix)***"
        }
        
        // Redact IPv4 addresses (keep first octet)
        sanitized = regexReplace(pattern: #"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b"#, in: sanitized) { match in
            if let firstOctet = match.split(separator: ".").first {
                return "\(firstOctet).***.***.***"
            }
            return "***.***.***.***"
        }
        
        // Redact IPv6 addresses (keep first segment)
        sanitized = regexReplace(pattern: #"\b[0-9a-fA-F:]+::[0-9a-fA-F:]+\b"#, in: sanitized) { match in
            if let firstSegment = match.split(separator: ":").first {
                return "\(firstSegment)::***"
            }
            return "***::***"
        }
        
        // Redact full IPv6 addresses
        sanitized = sanitized.replacingOccurrences(of: #"\b([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b"#, with: "***:***:***:***:***:***:***:***", options: .regularExpression)
        
        // Redact MAC addresses if any appear
        sanitized = sanitized.replacingOccurrences(of: #"\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"#, with: "**:**:**:**:**:**", options: .regularExpression)
        
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
    
    private func performCleanup() {
        let cutoffDate = Date().addingTimeInterval(-maxAgeHours * 3600)
        let originalCount = logs.count
        
        // Remove logs older than 24 hours
        logs.removeAll { log in
            log.timestamp < cutoffDate
        }
        
        let removedCount = originalCount - logs.count
        if removedCount > 0 {
            print("Debug log cleanup: removed \(removedCount) old entries, \(logs.count) logs remaining")
        }
    }
    
    func clearLogs() {
        logs.removeAll()
        lastCleanupTime = Date()
    }
    
    func forceCleanup() {
        performCleanup()
        lastCleanupTime = Date()
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
