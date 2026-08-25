import UIKit

/// UIKit-side URL handling — SwiftUI's onOpenURL does not reliably bridge
/// UIOpenURLAction on iOS 26 simulators; the plain app-delegate URL path
/// (application(_:open:)) always works for scheme-based deep links.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Scheme-based deep link while the app is running (foreground or
    /// background) — the reliable path on all iOS versions.
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        let payload = url.absoluteString
        UserDefaults.standard.set(payload, forKey: "e2e_last_open_url")
        NotificationCenter.default.post(
            name: Notification.Name("ShowPairingView"),
            object: nil,
            userInfo: ["payload": payload]
        )
        return true
    }

    /// Cold start with a deep-link URL (app not running).
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UserDefaults.standard.set("yes", forKey: "e2e_delegate_alive")
        if let url = launchOptions?[.url] as? URL {
            let payload = url.absoluteString
            UserDefaults.standard.set(payload, forKey: "e2e_last_open_url")
            // Post on next runloop tick so observers (the app's sheet state)
            // are registered by the time the notification fires.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("ShowPairingView"),
                    object: nil,
                    userInfo: ["payload": payload]
                )
            }
        }
        return true
    }
}