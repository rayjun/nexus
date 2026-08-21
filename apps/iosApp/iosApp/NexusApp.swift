import SwiftUI

@main
struct NexusApp: App {
    @StateObject private var relay: RelayClient
    @StateObject private var chatStore: ChatStore
    @State private var isShowingPairing = false
    @AppStorage("nexus_theme_light") private var lightTheme = true

    init() {
        let relay = RelayClient.shared
        _relay = StateObject(wrappedValue: relay)
        _chatStore = StateObject(wrappedValue: ChatStore(relay: relay))
    }

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(relay)
                .preferredColorScheme(lightTheme ? .light : .dark)
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShowPairingView"))) { _ in
                    isShowingPairing = true
                }
                .sheet(isPresented: $isShowingPairing) {
                    PairingView()
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