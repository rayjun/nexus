import Foundation
import os.log

private let relayLog = OSLog(subsystem: "com.rayjun.nexus", category: "Relay")

/// Manages multiple paired servers, each with its own relay connection.
/// Pairing = adding a server to the list; servers can be online simultaneously
/// and the UI switches the active one.
final class RelayClient: NSObject, ObservableObject {
    static let shared = RelayClient()

    @Published var servers: [ServerProfile] = []
    @Published var activeServerID: String?

    /// Connections keyed by server id.
    private var connections: [String: ServerConnection] = [:]

    var activeServer: ServerProfile? {
        servers.first { $0.id == activeServerID }
    }

    var isConnected: Bool {
        guard let id = activeServerID else { return false }
        return connections[id]?.isConnected ?? false
    }

    override init() {
        super.init()
        servers = ServerStore.load()
        if servers.isEmpty {
            // Migrate the legacy single-pairing state (pre-multi-server builds)
            if let migrated = ServerStore.migrateLegacyIfNeeded() {
                servers = ServerStore.load()
                activeServerID = migrated.id
                connect(serverID: migrated.id)
            }
        } else {
            activeServerID = servers.first?.id
            for s in servers {
                connect(serverID: s.id)
            }
        }
    }

    // MARK: - Server management

    /// Pair with a new server (relay URL + pairing code) — this ADDS a server.
    func addServer(relayURL: String, name: String? = nil, code: String) -> String {
        let channelID = E2ECrypto.channelIdFromPairingCode(code)
        let server = ServerProfile(
            id: UUID().uuidString,
            name: name ?? channelID,
            relayURL: relayURL,
            channelID: channelID,
            addedAt: Date(),
            lastConnectedAt: nil,
            isOnline: false
        )
        servers.append(server)
        ServerStore.save(servers)
        activeServerID = server.id

        let conn = ServerConnection(profile: server)
        conn.onStatusChange = { [weak self] in self?.refreshStatus(serverID: server.id) }
        conn.onPairingFailure = { [weak self] message in
            // Pairing failed — remove the just-added server so it doesn't
            // become a zombie that reconnects-and-fails forever.
            self?.removeServer(serverID: server.id)
            NotificationCenter.default.post(
                name: NSNotification.Name("RelayPairingFailed"),
                object: server.id,
                userInfo: ["message": message]
            )
        }
        connections[server.id] = conn
        conn.startPairing(code: code)
        return server.id
    }

    func connect(serverID: String) {
        guard let profile = servers.first(where: { $0.id == serverID }) else { return }
        if let conn = connections[serverID] {
            conn.connect()
        } else {
            let conn = ServerConnection(profile: profile)
            conn.onStatusChange = { [weak self] in self?.refreshStatus(serverID: serverID) }
            connections[serverID] = conn
            conn.connect()
        }
    }

    func disconnect(serverID: String) {
        connections[serverID]?.disconnect()
    }

    func removeServer(serverID: String) {
        if let conn = connections[serverID] {
            conn.disconnect()  // sets shouldReconnect=false — no zombie reconnect
            conn.clearKeys()
        }
        connections.removeValue(forKey: serverID)
        servers.removeAll { $0.id == serverID }
        ServerStore.save(servers)
        if activeServerID == serverID {
            activeServerID = servers.first?.id
        }
    }

    func setActive(serverID: String) {
        activeServerID = serverID
        connect(serverID: serverID)
    }

    private func refreshStatus(serverID: String) {
        // URLSession delegate queues are non-main; hop to main before
        // mutating @Published state / writing UserDefaults.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let conn = self.connections[serverID],
                  let idx = self.servers.firstIndex(where: { $0.id == serverID }) else { return }
            self.servers[idx].isOnline = conn.isConnected
            if conn.isConnected {
                self.servers[idx].lastConnectedAt = Date()
            }
            ServerStore.save(self.servers)
            self.objectWillChange.send()
        }
    }

    // MARK: - RPC routing (active server)

    func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        guard let id = activeServerID, let conn = connections[id] else {
            throw NSError(domain: "Nexus", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No active server"])
        }
        return try await conn.call(method, params: params)
    }

    func disconnect() {
        if let id = activeServerID {
            connections[id]?.disconnect()
        }
    }
}
