import Foundation

/// A paired server (Hermes Agent) reachable through a relay.
/// Pairing = adding a server; multiple servers can coexist.
struct ServerProfile: Identifiable, Codable, Equatable {
    var id: String          // UUID, also used as Keychain key prefix
    var name: String        // display name, e.g. "Homelab Agent"
    var relayURL: String    // e.g. wss://relay.example.com/relay
    var channelID: String   // derived from the pairing code
    var addedAt: Date
    var lastConnectedAt: Date?
    /// Transient connection state — NEVER persisted (it would go stale across
    /// relaunches; the real value comes from the live connection).
    var isOnline: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, relayURL, channelID, addedAt, lastConnectedAt
    }
}

/// Persists the list of paired servers in UserDefaults.
enum ServerStore {
    private static let key = "nexus_servers_v1"

    static func load() -> [ServerProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let servers = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        return servers
    }

    static func save(_ servers: [ServerProfile]) {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Migrate legacy single-pairing state (relay_enc_key etc.) into a server.
    /// Returns the migrated server if legacy pairing existed.
    static func migrateLegacyIfNeeded() -> ServerProfile? {
        let chId = KeychainHelper.load(key: "relay_channel_id")
        let encKey = KeychainHelper.load(key: "relay_enc_key")
        guard !chId.isEmpty, !encKey.isEmpty else { return nil }
        // Already migrated?
        if load().contains(where: { $0.channelID == chId }) { return nil }

        let relay = UserDefaults.standard.string(forKey: "relay_url")
            ?? (Bundle.main.object(forInfoDictionaryKey: "NexusRelayURL") as? String)
            ?? "wss://relay.example.com/relay"
        let server = ServerProfile(
            id: UUID().uuidString,
            name: "Hermes Agent",
            relayURL: relay,
            channelID: chId,
            addedAt: Date(),
            lastConnectedAt: nil,
            isOnline: false
        )
        var servers = load()
        servers.append(server)
        save(servers)
        return server
    }
}
