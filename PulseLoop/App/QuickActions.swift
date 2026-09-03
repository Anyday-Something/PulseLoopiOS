import Observation
import SwiftUI
import UIKit

/// Home-screen quick actions (long-press the app icon). iOS always launches the app for one; the app
/// routes it straight into the action so the user never has to find a button.
enum QuickAction: String, CaseIterable {
    /// Re-run the connect handshake + history sync, reconnecting first if the link is down.
    case sync = "com.pulseloop.sync"
}

/// Hands a shortcut from the scene delegate to the SwiftUI app. Cold start sets `pending` before any
/// view exists, so the app checks it when the scene becomes active as well as observing changes.
@MainActor
@Observable
final class QuickActionRouter {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = QuickActionRouter()
    private(set) var pending: QuickAction?

    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(rawValue: item.type) else { return false }
        pending = action
        return true
    }

    /// The pending action, cleared in the same step.
    func consume() -> QuickAction? {
        defer { pending = nil }
        return pending
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            Task { @MainActor in QuickActionRouter.shared.handle(item) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in completionHandler(QuickActionRouter.shared.handle(shortcutItem)) }
    }
}
