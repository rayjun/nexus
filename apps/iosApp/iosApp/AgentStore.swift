import Foundation

enum AgentStore {
    private static let agentsKey = "nexus_agents_v1"
    private static let chatsKey = "nexus_agent_chats_v1"

    static func loadAgents() -> [Agent] {
        guard let data = UserDefaults.standard.data(forKey: agentsKey),
              let agents = try? JSONDecoder().decode([Agent].self, from: data)
        else { return [] }
        return agents
    }

    static func saveAgents(_ agents: [Agent]) {
        if let data = try? JSONEncoder().encode(agents) {
            UserDefaults.standard.set(data, forKey: agentsKey)
        }
    }

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

    static func seedCandidates(from sessions: [SessionSummary]) -> [Agent] {
        sessions.map { s in
            Agent(
                id: Agent.localID(),
                serverID: "",
                boundSessionID: s.id,
                name: s.title.isEmpty ? "Agent" : s.title,
                icon: "sparkles",
                description: s.preview,
                status: .ready,
                createdAt: Date(),
                updatedAt: Date(),
                lastPreview: s.preview
            )
        }
    }
}

@MainActor
final class AgentRegistry: ObservableObject {
    @Published var agents: [Agent] {
        didSet { AgentStore.saveAgents(agents) }
    }
    @Published var chats: [String: [TimelineItem]] {
        didSet { AgentStore.saveChats(chats) }
    }

    init() {
        agents = AgentStore.loadAgents()
        chats = AgentStore.loadChats()
    }

    func upsert(_ agent: Agent) {
        var a = agent
        a.updatedAt = Date()
        if let idx = agents.firstIndex(where: { $0.id == a.id }) {
            agents[idx] = a
        } else {
            agents.append(a)
        }
        agents = agents   // trigger @Published didSet (index mutation is in-place)
    }

    /// Stable-id binding: keep Identifiable.id fixed, mutate boundSessionID in place.
    func bindSession(agentID: String, sessionID: String) {
        guard let idx = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[idx].boundSessionID = sessionID
        agents[idx].updatedAt = Date()
        agents = agents   // trigger @Published didSet
    }

    func remove(id: String) {
        agents.removeAll { $0.id == id }
        chats.removeValue(forKey: id)
    }

    func updateStatus(for serverID: String, isOnline: Bool, lastError: String? = nil) {
        var changed = false
        for i in agents.indices where agents[i].serverID == serverID {
            let newStatus: AgentStatus = isOnline ? .ready : .offline
            if agents[i].status != newStatus || agents[i].lastError != lastError {
                agents[i].status = newStatus
                agents[i].lastError = lastError
                agents[i].updatedAt = Date()
                changed = true
            }
        }
        if changed { agents = agents }   // trigger @Published didSet (index mutation is in-place)
    }

    func setLostKeys(for serverID: String, message: String) {
        var changed = false
        for i in agents.indices where agents[i].serverID == serverID {
            if agents[i].status != .lostKeys || agents[i].lastError != message {
                agents[i].status = .lostKeys
                agents[i].lastError = message
                agents[i].updatedAt = Date()
                changed = true
            }
        }
        if changed { agents = agents }
    }

    func setPreview(for id: String, preview: String) {
        guard let idx = agents.firstIndex(where: { $0.id == id }) else { return }
        var updated = agents[idx]
        updated.lastPreview = preview
        updated.lastMessageAt = Date()
        updated.updatedAt = Date()
        agents[idx] = updated
        agents = agents   // trigger @Published didSet
    }

    func messages(for id: String) -> [TimelineItem] { chats[id] ?? [] }

    func setMessages(_ items: [TimelineItem], for id: String) {
        chats[id] = Array(items.suffix(200))
    }
}
