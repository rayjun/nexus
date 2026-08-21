import Foundation

/// Persistence for the server-truth roster and per-bot caches.
/// Mirrors the v1 AgentStore/ServerStore split: pure storage, no logic.
/// Legacy `nexus_agents_v1` / `nexus_agent_chats_v1` keys are ABANDONED —
/// old sessions resurface via profiles.list last_session; no migration.
enum BotStore {
    private static let rosterKey = "nexus_roster_v2"
    private static let chatsKey = "nexus_chats_v2"
    private static let preferredKey = "nexus_preferred_v2"

    // MARK: roster (last-good cache, keyed by composite bot id)

    static func loadRoster() -> [Bot] {
        guard let data = UserDefaults.standard.data(forKey: rosterKey),
              let bots = try? JSONDecoder().decode([Bot].self, from: data)
        else { return [] }
        return bots
    }

    static func saveRoster(_ bots: [Bot]) {
        if let data = try? JSONEncoder().encode(bots) {
            UserDefaults.standard.set(data, forKey: rosterKey)
        }
    }

    // MARK: timeline cache (keyed by composite bot id, capped)

    static func loadChats() -> [String: [TimelineItem]] {
        guard let data = UserDefaults.standard.data(forKey: chatsKey),
              let chats = try? JSONDecoder().decode([String: [TimelineItem]].self, from: data)
        else { return [:] }
        return chats
    }

    static func saveChats(_ chats: [String: [TimelineItem]]) {
        let trimmed: [String: [TimelineItem]] = chats.mapValues { Array($0.suffix(200)) }
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: chatsKey)
        }
    }

    // MARK: preferred session map (bot composite id -> live sid)

    static func loadPreferred() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: preferredKey) as? [String: String] ?? [:]
    }

    static func savePreferred(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: preferredKey)
    }
}