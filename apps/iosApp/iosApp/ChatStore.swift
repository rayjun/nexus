import Foundation
import os.log

/// Minimal surface ChatStore needs from the transport — a protocol so the
/// store's business logic (merge/tombstone/prune/preferred) is unit-testable
/// with a fake.
protocol RelayClientProtocol: AnyObject {
    var servers: [ServerProfile] { get }
    func call(serverID: String, method: String, params: [String: Any]) async throws -> Any
}

extension RelayClient: RelayClientProtocol {}

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

    private let relay: RelayClientProtocol
    private let log = OSLog(subsystem: "com.rayjun.nexus", category: "ChatStore")

    init(relay: RelayClientProtocol) {
        self.relay = relay
        bots = BotStore.loadRoster()
        chats = BotStore.loadChats()
        preferredSessions = BotStore.loadPreferred()
        // Prune cached bots whose server no longer exists (e.g. a duplicate
        // server entry was dropped at RelayClient startup dedupe) — they can
        // never come back online.
        let liveIDs = Set(relay.servers.map(\.id))
        if bots.contains(where: { !liveIDs.contains($0.serverID) }) {
            bots = bots.filter { liveIDs.contains($0.serverID) }
        }
    }

    // MARK: Roster

    /// Refresh the roster from every paired server (server truth). Offline
    /// servers keep their last-good cache, marked .offline (dimmed in UI).
    /// Tombstoned bots are filtered out on merge — a re-pull must not
    /// resurrect a local delete.
    func refreshRoster() async {
        let onlineIDs = Set(relay.servers.filter(\.isOnline).map(\.id))
        // Mark cached bots of offline servers .offline first.
        var statusChanged = false
        for i in bots.indices where bots[i].status == .online && !onlineIDs.contains(bots[i].serverID) {
            bots[i].status = .offline
            statusChanged = true
        }
        if statusChanged { bots = bots }

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
                        if old.isTombstoned {
                            // A tombstoned bot must NOT resurrect to .online —
                            // keep the tombstone status so it stays hidden.
                            b.status = .tombstoned
                        }
                        // Keep the previous timestamp unless content changed —
                        // otherwise every refresh rewrites UserDefaults.
                        b.updatedAt = old.updatedAt
                    }
                    if let pref = preferredSessions[b.id] {
                        b.preferredSessionID = pref
                    }
                    return b
                }
                let others = bots.filter { $0.serverID != server.id }
                let next = others + merged
                // Publish only on real change (Equatable ignores nothing here;
                // field-level updates above already mutate copies).
                if next != bots {
                    bots = next
                }
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
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Send ONLY display_name — re-sending the cached descriptor could
        // clobber server-side description edits made elsewhere.
        _ = try await relay.call(serverID: bot.serverID, method: "profiles.configure",
                                 params: ["display_name": trimmed])
        var b = bot
        b.displayName = trimmed
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

    // MARK: - Streaming (live assistant output)

    /// Accumulate a streaming assistant reply under a synthetic item id
    /// `stream:<sessionID>`; `finishStream` seals it into the timeline.
    func appendStream(botID: String, sessionID: String?, text: String) {
        let key = "stream:\(sessionID ?? "pending")"
        var items = chats[botID] ?? []
        if let idx = items.firstIndex(where: { $0.id == key }) {
            let old = items[idx]
            items[idx] = TimelineItem(id: key, type: "assistant",
                                      text: (old.text ?? "") + text,
                                      markdown: nil, title: nil,
                                      timestamp: old.timestamp, toolName: nil, toolCalls: nil)
        } else {
            items.append(TimelineItem(id: key, type: "assistant", text: text,
                                      markdown: nil, title: nil,
                                      timestamp: ISO8601DateFormatter().string(from: Date()),
                                      toolName: nil, toolCalls: nil))
        }
        chats[botID] = Array(items.suffix(200))
    }

    func finishStream(botID: String, sessionID: String?, finalText: String? = nil) {
        let key = "stream:\(sessionID ?? "pending")"
        guard var items = chats[botID] else { return }
        guard let idx = items.firstIndex(where: { $0.id == key }) else { return }
        var item = items[idx]
        if let finalText {
            item = TimelineItem(id: item.id, type: "assistant", text: finalText,
                                markdown: nil, title: nil, timestamp: item.timestamp,
                                toolName: nil, toolCalls: nil)
        }
        items[idx] = item
        chats[botID] = Array(items.suffix(200))
    }
}