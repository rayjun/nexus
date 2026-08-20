import Foundation

// MARK: - Data Models (used by ContentView UI)

struct AgentInfo: Decodable, Identifiable {
    let id: String
    let name: String
    let baseUrl: String
    let status: String
    let profile: String
    let model: String
    let createdAt: String
    let lastSeenAt: String?
}

struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String
    let messageCount: Int
    let status: String
    let createdAt: String
    let updatedAt: String
}

struct SessionTimeline: Decodable {
    let items: [TimelineItem]
}

struct TimelineItem: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let text: String?
    let markdown: String?
    let title: String?
    let timestamp: String
    let toolName: String?
    let toolCalls: String?
}

struct PersistentAgent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let capabilities: [String]
    let linkedSessionIds: [String]
    let createdAt: String
    let updatedAt: String
    let lastMessageAt: String?
}

struct PersistentAgentMessage: Decodable, Identifiable {
    let id: String
    let agentId: String
    let role: String
    let content: String
    let createdAt: String
}

struct CronJobInfo: Decodable, Identifiable {
    let id: String
    let name: String
    let schedule: String
    let enabled: Bool
    let nextRunAt: String?
    let lastRun: CronRunInfo?
}

struct CronRunInfo: Decodable {
    let status: String
    let summary: String
    let finishedAt: String?
}

struct ApprovalInfo: Decodable, Identifiable {
    let id: String
    let toolName: String
    let command: String
    let title: String?
    let summary: String?
    let status: String
    let createdAt: String
}

struct ArtifactInfo: Decodable, Identifiable {
    let id: String
    let sessionId: String
    let name: String
    let title: String?
    let summary: String?
    let type: String
    let createdAt: String
}