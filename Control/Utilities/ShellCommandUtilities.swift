import Foundation

struct ShellCommandUtilities {
    
    /// Escapes special bash characters in a string to prevent shell injection and parsing errors
    /// - Parameter input: The string to escape
    /// - Returns: The escaped string safe for use in bash commands
    static func escapeBashString(_ input: String) -> String {
        return input
            .replacingOccurrences(of: "\\", with: "\\\\")  // Must be first to avoid double-escaping
            .replacingOccurrences(of: "\"", with: "\\\"")  // Escape double quotes
            .replacingOccurrences(of: "$", with: "\\$")    // Escape variable substitution
            .replacingOccurrences(of: "`", with: "\\`")    // Escape command substitution
    }
    
    /// Returns raw AppleScript intended to be streamed into a long-lived `osascript -` process.
    /// Nothing is escaped or wrapped — the caller is responsible for adding any sentinel afterwards.
    static func appleScriptForStreaming(_ appleScript: String) -> String {
        return appleScript
    }
} 
