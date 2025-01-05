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
    
    static let shared = UserPreferences()
    
    private init() {
        self.tintColor = UserDefaults.standard.string(forKey: "appTintColor") ?? "green"
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
} 
