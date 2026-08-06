import SwiftUI

@main
struct NexusApp: App {
    @StateObject private var relay = RelayClient.shared

    var body: some Scene {
        WindowGroup {
            if relay.servers.isEmpty {
                PairingView()
                    .environmentObject(relay)
            } else {
                ContentView()
                    .environmentObject(relay)
            }
        }
    }
}
