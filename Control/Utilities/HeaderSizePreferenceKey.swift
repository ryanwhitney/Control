import SwiftUI

/// Reports a header's measured height up the view tree so scroll content can
/// pad itself below the gradient header (used by ChooseApps and Permissions).
struct HeaderSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}
