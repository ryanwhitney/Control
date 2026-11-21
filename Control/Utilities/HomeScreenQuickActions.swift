import UIKit
import Combine

/// The Home Screen quick actions: one per saved Mac, each opening straight to
/// it. iOS delivers a chosen action to the scene delegate — at launch, or to
/// a running app — and this hands it to the SwiftUI side.
@MainActor
final class HomeScreenQuickActions: ObservableObject {
    static let shared = HomeScreenQuickActions()

    /// The hostname of a chosen action not yet acted on.
    @Published var requestedHost: String?

    private static let openConnectionType = "openConnection"
    private static let hostKey = "host"
    /// The Home Screen shows four at most.
    private static let maxItems = 4

    func update(for connections: [Connection]) {
        UIApplication.shared.shortcutItems = connections.prefix(Self.maxItems).map { connection in
            UIApplicationShortcutItem(
                type: Self.openConnectionType,
                localizedTitle: connection.name,
                localizedSubtitle: connection.name == connection.host ? nil : connection.host,
                icon: UIApplicationShortcutIcon(systemImageName: "desktopcomputer"),
                userInfo: [Self.hostKey: connection.host as NSString]
            )
        }
    }

    /// Whether `item` was one of these, so iOS can be told it was handled.
    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == Self.openConnectionType,
              let host = item.userInfo?[Self.hostKey] as? String else { return false }
        requestedHost = host
        return true
    }
}

final class ControlAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ControlSceneDelegate.self
        return configuration
    }
}

/// SwiftUI still owns the window; this only receives quick actions.
final class ControlSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let item = connectionOptions.shortcutItem else { return }
        MainActor.assumeIsolated {
            _ = HomeScreenQuickActions.shared.handle(item)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let handled = MainActor.assumeIsolated {
            HomeScreenQuickActions.shared.handle(shortcutItem)
        }
        completionHandler(handled)
    }
}
