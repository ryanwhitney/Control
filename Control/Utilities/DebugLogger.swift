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
        
        
        // Sanitize network-related sensitive information
        sanitized = sanitizeNetworkInfo(sanitized)

        // Sanitize media titles/artists from script output
        sanitized = sanitizeMediaContent(sanitized)

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
    
    /// Redacts probable media titles/artists (the first two fields of the
    /// separated status shape) while leaving system messages readable.
    private func sanitizeMediaContent(_ message: String) -> String {
        guard message.contains(ScriptTokens.fieldSeparator) else { return message }

        // Redact only the payload after "Full output: " when present; plain
        // messages carrying system/error keywords are left alone entirely.
        let prefix: String
        let payload: String
        if let range = message.range(of: "Full output: ") {
            prefix = String(message[..<range.upperBound])
            payload = String(message[range.upperBound...])
        } else {
            let lowered = message.lowercased()
            let systemKeywords = [
                "not running", "nothing playing", "loading", "permissions required",
                "no media", "error", "failed", "connection", "timeout", "authentication"
            ]
            if systemKeywords.contains(where: lowered.contains) { return message }
            prefix = ""
            payload = message
        }

        var components = payload.components(separatedBy: ScriptTokens.fieldSeparator)
        guard components.count >= 2 else { return message }

        let systemValues = [
            "not running", "nothing playing", "loading...", "permissions required",
            "no media playing", "error:", "no windows open", "no media found",
            "stopped", "false", "true", "playing", "paused"
        ]
        for index in 0...1 {
            let value = components[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = value.lowercased()
            let isSystemValue = systemValues.contains { lowered.contains($0) || $0.contains(lowered) }
            if value.count > 3 && !isSystemValue {
                components[index] = String(value.prefix(3)) + "***"
            }
        }
        return prefix + components.joined(separator: ScriptTokens.fieldSeparator)
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

    var allLogsText: String {
        logs.map { $0.formattedEntry }.joined(separator: "\n")
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
