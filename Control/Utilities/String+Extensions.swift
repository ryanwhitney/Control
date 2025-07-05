import Foundation

extension String {
    /// Returns a redacted version of the string for logging purposes.
    /// Example: "My Private Video" becomes "My P***"
    func redacted() -> String {
        guard !self.isEmpty else { return "" }
        let length = self.count
        if length <= 4 {
            return String(self.prefix(1)) + "***"
        } else {
            let prefixLength = min(length / 2, 4)
            return String(self.prefix(prefixLength)) + "***"
        }
    }
} 