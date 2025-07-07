import Foundation

extension String {
    /// Returns a redacted version of the string for logging purposes.
    /// Example: "My Private Video" becomes "My P***"
    func redacted() -> String {
        guard !self.isEmpty else { return "" }
        let prefixLength = min(2, self.count)
        return String(self.prefix(prefixLength)) + "***"
    }
} 
