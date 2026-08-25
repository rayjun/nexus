import SwiftUI
import os.log

@main
struct NexusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let log = OSLog(subsystem: "com.rayjun.nexus", category: "App")
    @StateObject private var relay: RelayClient
    @StateObject private var chatStore: ChatStore
    @State private var isShowingPairing = false
    @State private var pendingPairingPayload: String?
    @AppStorage("nexus_theme_light") private var lightTheme = true

    init() {
        let relay = RelayClient.shared
        _relay = StateObject(wrappedValue: relay)
        _chatStore = StateObject(wrappedValue: ChatStore(relay: relay))
        // E2E/deep-link bootstrap: an external payload pre-seeded in
        // UserDefaults (e.g. `simctl spawn booted defaults write …`) starts
        // the pairing flow automatically. Consumed once, then cleared.
        if let payload = UserDefaults.standard.string(forKey: "pending_pairing_payload"),
           !payload.isEmpty {
            _pendingPairingPayload = State(initialValue: payload)
            _isShowingPairing = State(initialValue: true)
            UserDefaults.standard.removeObject(forKey: "pending_pairing_payload")
        }
    }

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(relay)
                .preferredColorScheme(lightTheme ? .light : .dark)
                .onOpenURL { url in
                    // External pairing entry: nexus://host[:port]/path?code=..&name=..
                    // (used by `simctl openurl`, share sheets, deep links).
                    UserDefaults.standard.set(url.absoluteString, forKey: "e2e_last_open_url")
                    if url.scheme?.lowercased() == "nexus" {
                        // Re-encode so PairingView's QR parser sees the exact
                        // payload it already understands (scheme + host retained).
                        let payload = url.absoluteString
                        NotificationCenter.default.post(
                            name: Notification.Name("ShowPairingView"),
                            object: nil,
                            userInfo: ["payload": payload]
                        )
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShowPairingView"))) { note in
                    isShowingPairing = true
                    if let payload = note.userInfo?["payload"] as? String {
                        pendingPairingPayload = payload
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RelayPaired"))) { _ in
                    // Pairing succeeded — close the sheet; the root already
                    // switched to ChatListView (servers non-empty).
                    isShowingPairing = false
                    pendingPairingPayload = nil
                    Task { await chatStore.refreshRoster() }
                }
                .sheet(isPresented: $isShowingPairing) {
                    PairingView(pendingPayload: pendingPairingPayload, autoPair: true)
                        .environmentObject(relay)
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        if relay.servers.isEmpty {
            PairingView()
        } else {
            ChatListView(store: chatStore)
        }
    }
}