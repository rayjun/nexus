import Foundation

enum AgentStatus: String, Codable {
    case ready
    case offline
    case lostKeys
    case unpaired
}

struct Agent: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var serverID: String
    // nil => no server thread yet (local-only agent until first prompt)
    var boundSessionID: String?
    var name: String
    var icon: String
    var description: String
    var status: AgentStatus
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
    var lastMessageAt: Date?
    var lastPreview: String?

    init(
        id: String,
        serverID: String,
        boundSessionID: String? = nil,
        name: String,
        icon: String = "sparkles",
        description: String = "",
        status: AgentStatus = .ready,
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastMessageAt: Date? = nil,
        lastPreview: String? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.boundSessionID = boundSessionID
        self.name = name
        self.icon = icon
        self.description = description
        self.status = status
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
        self.lastPreview = lastPreview
    }

    var displayName: String { name.isEmpty ? "Agent" : name }

    var isLocalOnly: Bool { boundSessionID == nil }

    static func localID() -> String { UUID().uuidString }

    static func stableID(serverID: String, sessionID: String) -> String {
        "\(serverID):\(sessionID)"
    }
}
