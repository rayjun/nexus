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
        // Dedupe by channel up-front: pre-fix builds could persist multiple
        // entries for the same relay channel (the relay rejects the second
        // app join, leaving a hang-forever ghost). Keep the first, drop the
        // rest — their Keychain keys are already orphaned.
        var seen = Set<String>()
        let loaded = ServerStore.load()
        servers = loaded.filter { seen.insert($0.channelID).inserted }
        if servers.count != loaded.count {
            os_log("dropped %d duplicate server entries (loaded %d, kept %d)",
                   log: relayLog, type: .info, loaded.count - servers.count,
                   loaded.count, servers.count)
            ServerStore.save(servers)
        }
        os_log("init: %d servers — %@", log: relayLog, type: .info,
               servers.count, servers.map { "\($0.name)/\($0.channelID.prefix(8))" }.joined(separator: ", "))
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
    /// Idempotent per channel: pairing the same code again reuses the existing
    /// server entry instead of creating a second connection to the same relay
    /// channel (the relay allows ONE app per channel — a duplicate would be
    /// rejected at join and its RPCs would hang forever).
    func addServer(relayURL: String, name: String? = nil, code: String) -> String {
        let channelID = E2ECrypto.channelIdFromPairingCode(code)
        if let existing = servers.first(where: { $0.channelID == channelID }) {
            // Re-pair of an existing server: refresh URL/name, keep id so the
            // Keychain-stored E2E keys (keyed by server id) stay valid.
            if let idx = servers.firstIndex(where: { $0.id == existing.id }) {
                servers[idx].relayURL = relayURL
                if let name, !name.isEmpty { servers[idx].name = name }
            }
            ServerStore.save(servers)
            activeServerID = existing.id
            connections[existing.id]?.disconnect()
            connect(serverID: existing.id)
            return existing.id
        }
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

    func updateServer(serverID: String, relayURL: String? = nil, name: String? = nil) {
        guard let idx = servers.firstIndex(where: { $0.id == serverID }) else { return }
        if let relayURL { servers[idx].relayURL = relayURL }
        if let name { servers[idx].name = name }
        ServerStore.save(servers)
        // Reconnect with the new URL (disconnect first so connect() isn't a no-op)
        connections[serverID]?.disconnect()
        connect(serverID: serverID)
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

    /// Disconnect and forget every server (used by "Disconnect" — returns
    /// the app to the Add Server screen; next launch starts clean).
    func removeAllServers() {
        for id in Array(connections.keys) {
            removeServer(serverID: id)
        }
        servers = []
        ServerStore.save([])
        activeServerID = nil
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

    /// Per-server RPC routing — used by ChatStore roster refresh and chat
    /// targeting so one server's fetch never flips the UI's active server
    /// (v1 setActive-flip race). No connection state is mutated here.
    func call(serverID: String, method: String, params: [String: Any] = [:]) async throws -> Any {
        guard let conn = connections[serverID] else {
            throw NSError(domain: "Nexus", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No connection for server"])
        }
        return try await conn.call(method, params: params)
    }

    func disconnect() {
        if let id = activeServerID {
            connections[id]?.disconnect()
        }
    }
}
