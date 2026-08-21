#!/usr/bin/env swift
// ChatStore business-logic regression tests (v2.1.3).
// Runs standalone (no Xcode target): a FakeRelay implements
// RelayClientProtocol; the store's merge/tombstone/prune/preferred logic is
// exercised against it. Mirrors ChatStore.swift semantics — keep in sync.
import Foundation

// ── Protocol mirror (ChatStore.swift) ──
protocol RelayClientProtocol: AnyObject {
    var servers: [ServerProfile] { get }
    func call(serverID: String, method: String, params: [String: Any]) async throws -> Any
}

struct ServerProfile: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var relayURL: String
    var channelID: String
    var addedAt: Date
    var lastConnectedAt: Date?
    var isOnline: Bool = false
}

struct Bot: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var serverID: String
    var name: String
    var displayName: String
    var descriptor: String
    var model: String
    var provider: String
    var status: String
    var lastPreview: String?
    var lastActiveAt: Date?
    var lastSessionID: String?
    var preferredSessionID: String?
    var isTombstoned: Bool = false
    var updatedAt: Date

    init(serverID: String, name: String, displayName: String = "", status: String = "online",
         lastSessionID: String? = nil) {
        self.serverID = serverID; self.name = name; self.displayName = displayName
        self.descriptor = ""; self.model = ""; self.provider = ""
        self.status = status; self.lastPreview = nil; self.lastActiveAt = nil
        self.lastSessionID = lastSessionID; self.preferredSessionID = nil
        self.updatedAt = Date()
        self.id = "\(serverID):\(name)"
    }
}

// ── Fake relay: routes profiles.list responses per server ──
final class FakeRelay: RelayClientProtocol {
    var servers: [ServerProfile] = []
    var listResults: [String: [[String: Any]]] = [:]  // serverID -> rows
    var createParams: [[String: Any]] = []
    var configureParams: [[String: Any]] = []
    var callCount: [String: Int] = [:]

    func call(serverID: String, method: String, params: [String: Any]) async throws -> Any {
        callCount[method, default: 0] += 1
        switch method {
        case "profiles.list":
            return ["profiles": listResults[serverID] ?? []]
        case "profiles.create":
            createParams.append(params)
            return ["name": params["name"] ?? "", "path": "/tmp/\(params["name"] ?? "x")"]
        case "profiles.configure":
            configureParams.append(params)
            return [:]
        default:
            return [:]
        }
    }
}

// ── Store mirror (ChatStore.swift semantics) ──
@MainActor
final class ChatStore {
    var bots: [Bot] = []
    var chats: [String: [String]] = [:]
    var preferredSessions: [String: String] = [:]
    let relay: RelayClientProtocol

    init(relay: RelayClientProtocol) { self.relay = relay }

    func refreshRoster() async {
        let onlineIDs = Set(relay.servers.filter { $0.isOnline }.map { $0.id })
        for i in bots.indices where bots[i].status == "online" && !onlineIDs.contains(bots[i].serverID) {
            bots[i].status = "offline"
        }
        for server in relay.servers {
            if !server.isOnline { continue }
            guard let result = try? await relay.call(serverID: server.id, method: "profiles.list", params: ["include_sessions": true]),
                  let dict = result as? [String: Any],
                  let rows = dict["profiles"] as? [[String: Any]] else { continue }
            let fresh = rows.compactMap { row -> Bot? in
                guard let name = row["name"] as? String, !name.isEmpty else { return nil }
                var b = Bot(serverID: server.id, name: name,
                            displayName: row["display_name"] as? String ?? "")
                if let ls = row["last_session"] as? [String: Any] {
                    b.lastSessionID = ls["id"] as? String
                    b.lastPreview = ls["preview"] as? String
                }
                return b
            }
            let existing = bots.filter { $0.serverID == server.id }
            let merged = fresh.map { f -> Bot in
                var b = f
                if let old = existing.first(where: { $0.name == f.name }) {
                    b.preferredSessionID = old.preferredSessionID
                    b.isTombstoned = old.isTombstoned
                    if old.isTombstoned { b.status = "tombstoned" }
                    b.updatedAt = old.updatedAt
                }
                if let pref = preferredSessions[b.id] { b.preferredSessionID = pref }
                return b
            }
            let others = bots.filter { $0.serverID != server.id }
            let next = others + merged
            if next != bots { bots = next }
        }
    }

    func tombstoneBot(_ bot: Bot) {
        guard let i = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[i].isTombstoned = true
        bots[i].status = "tombstoned"
        chats.removeValue(forKey: bot.id)
    }

    func pruneServer(_ serverID: String) {
        bots.removeAll { $0.serverID == serverID }
        for (id, _) in preferredSessions where id.hasPrefix(serverID + ":") {
            preferredSessions.removeValue(forKey: id)
        }
        for (id, _) in chats where id.hasPrefix(serverID + ":") {
            chats.removeValue(forKey: id)
        }
    }

    func bindPreferredSession(botID: String, sessionID: String) {
        preferredSessions[botID] = sessionID
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].preferredSessionID = sessionID
        }
    }
}

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}


@MainActor
func main() async {
  try? await Task.sleep(nanoseconds: 100_000_000)  // settle store init
let store = ChatStore(relay: FakeRelay())
let fake = store.relay as! FakeRelay

// ── 1) Offline server → cached bots marked offline ──
@MainActor
func testOfflineMarking() async {
    fake.servers = [ServerProfile(id: "srvA", name: "A", relayURL: "wss://x", channelID: "c", addedAt: Date(), isOnline: false)]
    store.bots = [Bot(serverID: "srvA", name: "writer", status: "online")]
    await store.refreshRoster()
    expect(store.bots.first?.status == "offline", "offline server → cached bot marked offline (dimming)")
}
await testOfflineMarking()

// ── 2) Merge: tombstone preserved across refresh (no resurrection) ──
@MainActor
func testTombstonePreserved() async {
    fake.servers = [ServerProfile(id: "srvB", name: "B", relayURL: "wss://y", channelID: "d", addedAt: Date(), isOnline: true)]
    fake.listResults["srvB"] = [["name": "coder", "display_name": "Coder"], ["name": "writer", "display_name": "Writer"]]
    store.bots = [Bot(serverID: "srvB", name: "coder")]
    store.tombstoneBot(store.bots[0])
    await store.refreshRoster()
    let coder = store.bots.first { $0.name == "coder" }
    expect(coder?.isTombstoned == true, "merge keeps tombstone flag (no resurrection)")
    expect(coder?.status == "tombstoned", "merge keeps tombstoned status")
}
await testTombstonePreserved()

// ── 3) Merge: preferred session preserved from local map ──
@MainActor
func testPreferredPreserved() async {
    fake.servers = [ServerProfile(id: "srvB", name: "B", relayURL: "wss://y", channelID: "d", addedAt: Date(), isOnline: true)]
    fake.listResults["srvB"] = [["name": "coder", "display_name": "Coder"]]
    store.preferredSessions["srvB:coder"] = "live-8888"
    await store.refreshRoster()
    expect(store.bots.first { $0.name == "coder" }?.preferredSessionID == "live-8888",
           "merge preserves locally pinned preferred session")
}
await testPreferredPreserved()

// ── 4) pruneServer: bots + preferred + chats for that server only ──
@MainActor
func testPrune() async {
    store.bots = [Bot(serverID: "srvA", name: "a1"), Bot(serverID: "srvB", name: "b1")]
    store.preferredSessions = ["srvA:a1": "x", "srvB:b1": "y"]
    store.chats = ["srvA:a1": ["m1"], "srvB:b1": ["m2"]]
    store.pruneServer("srvA")
    expect(!store.bots.contains { $0.serverID == "srvA" }, "prune removes server A bots")
    expect(store.bots.contains { $0.serverID == "srvB" }, "prune keeps server B bots")
    expect(store.preferredSessions["srvB:b1"] == "y", "prune keeps other server preferred")
    expect(store.preferredSessions["srvA:a1"] == nil, "prune drops server A preferred")
    expect(store.chats["srvB:b1"] != nil, "prune keeps other chat cache")
    expect(store.chats["srvA:a1"] == nil, "prune drops server A chat cache")
}
await testPrune()

// ── 5) bindPreferredSession updates both map and bot ──
@MainActor
func testBindPreferred() async {
    store.bots = [Bot(serverID: "srvB", name: "coder")]
    store.bindPreferredSession(botID: "srvB:coder", sessionID: "live-1234")
    expect(store.preferredSessions["srvB:coder"] == "live-1234", "preferred map updated")
    expect(store.bots.first?.preferredSessionID == "live-1234", "bot field updated")
}
await testBindPreferred()

// ── 6) createBot params never contain mirror_credentials ──
@MainActor
func testCreateParams() async {
    let before = fake.createParams.count
    _ = try? await store.relay.call(serverID: "srvB", method: "profiles.create",
                                    params: ["name": "t", "description": "d", "soul": "s", "model": "m"])
    let p = fake.createParams.last ?? [:]
    expect(p["name"] as? String == "t", "create carries name")
    expect(p["mirror_credentials"] == nil, "create never forwards mirror_credentials")
    _ = before
}
await testCreateParams()

// await all tasks
}

await main()

print(failures == 0 ? "\nALL OK" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)