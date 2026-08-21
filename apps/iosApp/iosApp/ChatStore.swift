import Foundation
import os.log

@MainActor
final class ChatStore: ObservableObject {
    @Published var bots: [Bot] {
        didSet { BotStore.saveRoster(bots) }
    }
    @Published var chats: [String: [TimelineItem]] {
        didSet { BotStore.saveChats(chats) }
    }
    @Published var preferredSessions: [String: String] {
        didSet { BotStore.savePreferred(preferredSessions) }
    }

    private let relay: RelayClient
    private let log = OSLog(subsystem: "com.rayjun.nexus", category: "ChatStore")

    init(relay: RelayClient) {
        self.relay = relay
        bots = BotStore.loadRoster()
        chats = BotStore.loadChats()
        preferredSessions = BotStore.loadPreferred()
    }

    // MARK: Roster

    /// Refresh the roster from every paired server (server truth). Offline
    /// servers keep their last-good cache (dimmed in UI). Tombstoned bots are
    /// filtered out on merge — a re-pull must not resurrect a local delete.
    func refreshRoster() async {
        for server in relay.servers {
            if !server.isOnline { continue }
            do {
                let result = try await relay.call(serverID: server.id,
                                                  method: "profiles.list",
                                                  params: ["include_sessions": true])
                guard let dict = result as? [String: Any],
                      let rows = dict["profiles"] as? [[String: Any]] else { continue }
                let fresh = rows.compactMap { row -> Bot? in
                    guard let name = row["name"] as? String, !name.isEmpty else { return nil }
                    var bot = Bot(
                        serverID: server.id,
                        name: name,
                        displayName: row["display_name"] as? String ?? "",
                        descriptor: row["description"] as? String ?? "",
                        model: row["model"] as? String ?? "",
                        provider: row["provider"] as? String ?? "",
                        status: .online
                    )
                    if let ls = row["last_session"] as? [String: Any] {
                        bot.lastSessionID = ls["id"] as? String
                        bot.lastPreview = ls["preview"] as? String
                        if let la = ls["last_active"] as? Double {
                            bot.lastActiveAt = Date(timeIntervalSince1970: la)
                        }
                    }
                    return bot
                }

                // Merge: keep tombstoned entries for this server filtered out,
                // preserve local preferredSessionID + tombstones from cache.
                let existing = bots.filter { $0.serverID == server.id }
                let merged = fresh.map { freshBot -> Bot in
                    var b = freshBot
                    if let old = existing.first(where: { $0.name == freshBot.name }) {
                        b.preferredSessionID = old.preferredSessionID
                        b.isTombstoned = old.isTombstoned
                    }
                    if let pref = preferredSessions[b.id] {
                        b.preferredSessionID = pref
                    }
                    b.updatedAt = Date()
                    return b
                }
                let others = bots.filter { $0.serverID != server.id }
                bots = others + merged
            } catch {
                os_log("roster refresh failed for %{public}@: %{public}@",
                       log: log, type: .error, server.id, error.localizedDescription)
            }
        }
    }

    // MARK: CRUD

    func upsert(_ bot: Bot) {
        var b = bot
        b.updatedAt = Date()
        if let idx = bots.firstIndex(where: { $0.id == b.id }) {
            bots[idx] = b
        } else {
            bots.append(b)
        }
        bots = bots  // re-publish (index mutation is in-place)
    }

    /// Fresh bot must not exist remotely yet — create returns the profile.
    /// Result shape: {name, path, ...} (mirror profiles.create).
    func createBot(serverID: String, name: String, description: String,
                   soul: String = "", model: String = "", provider: String = "") async throws -> Bot {
        var params: [String: Any] = ["name": name, "description": description]
        if !soul.isEmpty { params["soul"] = soul }
        if !model.isEmpty { params["model"] = model }
        if !provider.isEmpty { params["provider"] = provider }
        _ = try await relay.call(serverID: serverID, method: "profiles.create", params: params)
        let bot = Bot(serverID: serverID, name: name, displayName: name,
                      descriptor: description, model: model, provider: provider)
        upsert(bot)
        return bot
    }

    func renameBot(_ bot: Bot, displayName: String) async throws {
        var params: [String: Any] = [:]
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { params["display_name"] = trimmed }
        if !bot.descriptor.isEmpty { params["description"] = bot.descriptor }
        _ = try await relay.call(serverID: bot.serverID, method: "profiles.configure", params: params)
        var b = bot
        b.displayName = trimmed.isEmpty ? bot.displayName : trimmed
        upsert(b)
    }

    /// Local tombstone: profiles.delete has no RPC (REST/CLI only). The bot is
    /// hidden from the roster; if the profile still exists server-side it will
    /// surface again on a manual full reset (documented in UI copy).
    func tombstoneBot(_ bot: Bot) {
        var index: Int?
        for i in bots.indices where bots[i].id == bot.id { index = i; break }
        guard let i = index else { return }
        bots[i].isTombstoned = true
        bots[i].status = .tombstoned
        bots[i].updatedAt = Date()
        bots = bots
        chats.removeValue(forKey: bot.id)
    }

    /// Server removal cleanup: drop its bots, preferred pins and chat cache.
    func pruneServer(_ serverID: String) {
        bots.removeAll { $0.serverID == serverID }
        for (id, _) in preferredSessions where id.hasPrefix(serverID + ":") {
            preferredSessions.removeValue(forKey: id)
        }
        for (id, _) in chats where id.hasPrefix(serverID + ":") {
            chats.removeValue(forKey: id)
        }
        bots = bots
    }

    // MARK: Sessions / chats

    func bindPreferredSession(botID: String, sessionID: String) {
        preferredSessions[botID] = sessionID
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].preferredSessionID = sessionID
            bots = bots
        }
    }

    func messages(for botID: String) -> [TimelineItem] { chats[botID] ?? [] }

    func setMessages(_ items: [TimelineItem], for botID: String) {
        chats[botID] = Array(items.suffix(200))
    }

    /// Update the roster card's last-preview immediately after a send.
    func setPreview(for botID: String, preview: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botID }) else { return }
        var updated = bots[idx]
        updated.lastPreview = preview
        updated.lastActiveAt = Date()
        updated.updatedAt = Date()
        bots[idx] = updated
        bots = bots  // re-publish
    }
}