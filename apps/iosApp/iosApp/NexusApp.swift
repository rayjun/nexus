import SwiftUI

@main
struct NexusApp: App {
    @StateObject private var relay = RelayClient.shared
    @StateObject private var agentRegistry = AgentRegistry()
    @State private var isShowingPairing = false

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(relay)
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShowPairingView"))) { note in
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
            AgentHomeView(registry: agentRegistry)
        }
    }
}
