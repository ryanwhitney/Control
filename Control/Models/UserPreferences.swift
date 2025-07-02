import SwiftUI

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
    
    static let shared = UserPreferences()
    
    private init() {
        self.tintColor = UserDefaults.standard.string(forKey: "appTintColor") ?? "green"
        self.lastSeenWhatsNewVersion = UserDefaults.standard.string(forKey: "lastSeenWhatsNewVersion") ?? ""
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
