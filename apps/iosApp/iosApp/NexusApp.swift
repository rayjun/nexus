import SwiftUI

@main
struct NexusApp: App {
    @StateObject private var relay = RelayClient.shared

    var body: some Scene {
        WindowGroup {
            if relay.isPaired {
                ContentView()
                    .environmentObject(relay)
            } else {
                PairingView()
                    .environmentObject(relay)
            }
        }
    }
}