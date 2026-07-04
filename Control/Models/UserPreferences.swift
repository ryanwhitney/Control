import SwiftUI

/// Which SSH transport the app uses. `streaming` is the default (fast: a
/// persistent `osascript -i` over a PTY); `compatibility` is the fallback for
/// Macs where streaming misbehaves (one `osascript` per command, no PTY).
enum ConnectionMethod: String, CaseIterable, Identifiable {
    case streaming
    case compatibility

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .streaming: return "Fast"
        case .compatibility: return "Compatibility"
        }
    }
}

@MainActor
class UserPreferences: ObservableObject {
    @Published var tintColor: String {
        didSet {
            withAnimation(.spring()) {
                UserDefaults.standard.set(tintColor, forKey: "appTintColor")
                objectWillChange.send()
            }
        }
    }
    
    @Published var lastSeenWhatsNewVersion: String {
        didSet {
            UserDefaults.standard.set(lastSeenWhatsNewVersion, forKey: "lastSeenWhatsNewVersion")
        }
    }

    /// Selected SSH transport. Applied on the next connect.
    @Published var connectionMethod: ConnectionMethod {
        didSet {
            UserDefaults.standard.set(connectionMethod.rawValue, forKey: "connectionMethod")
        }
    }

    static let shared = UserPreferences()

    private init() {
        self.tintColor = UserDefaults.standard.string(forKey: "appTintColor") ?? "green"
        self.lastSeenWhatsNewVersion = UserDefaults.standard.string(forKey: "lastSeenWhatsNewVersion") ?? ""
        self.connectionMethod = ConnectionMethod(rawValue: UserDefaults.standard.string(forKey: "connectionMethod") ?? "") ?? .streaming
    }
    
    var tintColorValue: Color {
        switch tintColor {
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        default: return .green
        }
    }
    
    // Update to show the what's new screen
    private let whatsNewContentVersion = "1.10"

    var shouldShowWhatsNew: Bool {
        return lastSeenWhatsNewVersion != whatsNewContentVersion
    }
    
    func markWhatsNewAsSeen() {
        lastSeenWhatsNewVersion = whatsNewContentVersion
    }
    
    // Force what's new screen to show again
    func resetWhatsNew() {
        lastSeenWhatsNewVersion = ""
    }
} 
