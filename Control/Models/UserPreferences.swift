import SwiftUI

/// `streaming` is a persistent `osascript -i` over a PTY; `compatibility` is
/// one `osascript` per command, for Macs where streaming falters or PTY is disabled.
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

    // Keyboard-controls promo (2.1.0): a self-clearing hint dot walks existing
    // users from the controls screen's More (⋯) menu → Manage Apps → the Keyboard
    // row in Choose Apps. The ⋯ button and Manage Apps dots share one flag (cleared
    // when Manage Apps is tapped); the Keyboard-row dot clears when that screen is
    // seen. Retire the promo by deleting these flags and the dots that read them.
    @Published var hasSeenKeyboardHintManageApps: Bool {
        didSet { UserDefaults.standard.set(hasSeenKeyboardHintManageApps, forKey: "hasSeenKeyboardHintManageApps") }
    }
    @Published var hasSeenKeyboardHintChooseApps: Bool {
        didSet { UserDefaults.standard.set(hasSeenKeyboardHintChooseApps, forKey: "hasSeenKeyboardHintChooseApps") }
    }

    static let shared = UserPreferences()

    private init() {
        self.tintColor = UserDefaults.standard.string(forKey: "appTintColor") ?? "green"
        self.lastSeenWhatsNewVersion = UserDefaults.standard.string(forKey: "lastSeenWhatsNewVersion") ?? ""
        self.connectionMethod = ConnectionMethod(rawValue: UserDefaults.standard.string(forKey: "connectionMethod") ?? "") ?? .streaming
        self.hasSeenKeyboardHintManageApps = UserDefaults.standard.bool(forKey: "hasSeenKeyboardHintManageApps")
        self.hasSeenKeyboardHintChooseApps = UserDefaults.standard.bool(forKey: "hasSeenKeyboardHintChooseApps")
    }
    
    /// The single source for the theme pickers and `tintColorValue`.
    static let themeColors: [(name: String, key: String, color: Color)] = [
        ("Blue", "blue", .blue),
        ("Indigo", "indigo", .indigo),
        ("Purple", "purple", .purple),
        ("Pink", "pink", .pink),
        ("Red", "red", .red),
        ("Orange", "orange", .orange),
        ("Green", "green", .green),
        ("Mint", "mint", .mint),
        ("Teal", "teal", .teal),
        ("Cyan", "cyan", .cyan)
    ]

    var tintColorValue: Color {
        Self.themeColors.first { $0.key == tintColor }?.color ?? .green
    }
    
    /// Bump to show the What's New screen again.
    private let whatsNewContentVersion = "2.1.0"

    var shouldShowWhatsNew: Bool {
        return lastSeenWhatsNewVersion != whatsNewContentVersion
    }
    
    func markWhatsNewAsSeen() {
        lastSeenWhatsNewVersion = whatsNewContentVersion
    }

    func markKeyboardHintManageAppsSeen() {
        if !hasSeenKeyboardHintManageApps { hasSeenKeyboardHintManageApps = true }
    }
    func markKeyboardHintChooseAppsSeen() {
        if !hasSeenKeyboardHintChooseApps { hasSeenKeyboardHintChooseApps = true }
    }

    /// Debug-only: re-arms the hint dots.
    func resetKeyboardHints() {
        hasSeenKeyboardHintManageApps = false
        hasSeenKeyboardHintChooseApps = false
    }

    /// Debug-only: shows What's New again on the next launch.
    func resetWhatsNewSeen() {
        lastSeenWhatsNewVersion = ""
    }
}

extension View {
    /// Sets both colour channels from one source. `.tint` and `Color.accentColor`
    /// read different environment values, and neither crosses a sheet boundary,
    /// so every sheet root needs this or the two disagree inside it.
    func themeTint(_ color: Color) -> some View {
        tint(color).accentColor(color)
    }
}
