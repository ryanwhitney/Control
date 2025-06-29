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
    
    /// Wraps an AppleScript command in a bash command that will work regardless of the user's default shell
    /// - Parameter appleScript: The AppleScript code to execute
    /// - Returns: A bash command string that safely executes the AppleScript
    static func wrapAppleScriptForBash(_ appleScript: String) -> String {
        let escapedScript = escapeBashString(appleScript)
        
        return """
        bash -c "osascript << 'APPLESCRIPT'
        try
            \(escapedScript)
        on error errMsg
            return errMsg
        end try
        APPLESCRIPT"
        """
    }
} 
