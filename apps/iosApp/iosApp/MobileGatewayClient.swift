import Foundation

// MARK: - Data Models

struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String
    let messageCount: Int
    let status: String
    let createdAt: String
    let updatedAt: String
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
