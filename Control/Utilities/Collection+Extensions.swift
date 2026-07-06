import Foundation

extension Array {
    /// Returns the element at `index`, or nil when out of bounds.
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < endIndex else { return nil }
        return self[index]
    }
}
