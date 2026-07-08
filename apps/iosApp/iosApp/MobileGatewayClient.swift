import Foundation

struct MobileStatus: Decodable {
    let nodeId: String
    let nodeName: String
    let status: String
    let gatewayReady: Bool
    let hermesVersion: String
    let apiVersion: String
    let profile: String
    let model: [String: String]
    let features: [String: Bool]
}

struct PairingStart: Decodable {
    let pairingId: String
    let code: String
    let expiresAt: String
    let qrPayload: String
}

struct PairingComplete: Decodable {
    let deviceId: String
    let deviceToken: String
    let capabilities: [String: Bool]
}

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

struct AgentsResponse: Decodable {
    let agents: [AgentInfo]
}

struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let createdAt: String
    let updatedAt: String
}

struct SessionsResponse: Decodable {
    let sessions: [SessionSummary]
}

struct SessionTimeline: Decodable {
    let sessionId: String
    let title: String
    let items: [TimelineItem]
}

struct TimelineItem: Decodable, Identifiable {
    let type: String
    let id: String
    let createdAt: String
    let text: String?
    let title: String?
    let markdown: String?
    let toolCalls: [ToolCall]?
}

struct ToolCall: Decodable, Identifiable {
    let id: String
    let name: String
    let summary: String
    let status: String
    let durationMs: Int?
    let error: String?
}

struct GoalResponse: Decodable {
    let session: SessionSummary
    let timeline: SessionTimeline
}

struct PersistentAgent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    var icon: String = "sparkles"
    let capabilities: [String]
    let linkedSessionIds: [String]
    let createdAt: String
    let updatedAt: String
    let lastMessageAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles"
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        linkedSessionIds = try c.decodeIfPresent([String].self, forKey: .linkedSessionIds) ?? []
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        lastMessageAt = try c.decodeIfPresent(String.self, forKey: .lastMessageAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, icon, capabilities
        case linkedSessionIds = "linked_session_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastMessageAt = "last_message_at"
    }
}

struct PersistentAgentsResponse: Decodable {
    let agents: [PersistentAgent]
}

struct PersistentAgentMessage: Decodable, Identifiable {
    let id: String
    let agentId: String
    let role: String
    let content: String
    let createdAt: String
}

struct AgentMessagesResponse: Decodable {
    let messages: [PersistentAgentMessage]
}

struct AgentMessageResponse: Decodable {
    let userMessage: PersistentAgentMessage
    let assistantMessage: PersistentAgentMessage
}

enum MobileGatewayError: Error, LocalizedError {
    case invalidURL
    case badStatus(Int)
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid gateway URL"
        case .badStatus(let code):
            return "Gateway returned HTTP \(code)"
        case .emptyToken:
            return "Missing device token"
        }
    }
}

final class MobileGatewayClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: String, session: URLSession = .shared) {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        self.baseURL = URL(string: normalized) ?? URL(string: "http://127.0.0.1:8765")!
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func status() async throws -> MobileStatus {
        try await get("/mobile/v1/status")
    }

    func startPairing() async throws -> PairingStart {
        try await post("/mobile/v1/pair/start", body: EmptyBody())
    }

    func completePairing(code: String, deviceName: String, platform: String) async throws -> PairingComplete {
        try await post("/mobile/v1/pair/complete", body: PairingCompleteBody(code: code, deviceName: deviceName, platform: platform))
    }

    func sessions(deviceToken: String) async throws -> [SessionSummary] {
        if deviceToken.isEmpty {
            throw MobileGatewayError.emptyToken
        }
        let response: SessionsResponse = try await get("/mobile/v1/sessions", token: deviceToken)
        return response.sessions
    }

    func agents(deviceToken: String) async throws -> [AgentInfo] {
        if deviceToken.isEmpty {
            throw MobileGatewayError.emptyToken
        }
        let response: AgentsResponse = try await get("/mobile/v1/agents", token: deviceToken)
        return response.agents
    }

    func addAgent(name: String, baseURL: String, deviceToken: String) async throws -> AgentInfo {
        if deviceToken.isEmpty {
            throw MobileGatewayError.emptyToken
        }
        return try await post("/mobile/v1/agents", body: AgentBody(name: name, baseUrl: baseURL), token: deviceToken)
    }

    func removeAgent(id: String, deviceToken: String) async throws {
        if deviceToken.isEmpty {
            throw MobileGatewayError.emptyToken
        }
        var request = try request(path: "/mobile/v1/agents/\(id)", method: "DELETE")
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        try await sendEmpty(request)
    }

    func updateAgent(id: String, name: String, baseURL: String, deviceToken: String) async throws -> AgentInfo {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        return try await post("/mobile/v1/agents/\(id)", body: AgentBody(name: name, baseUrl: baseURL), token: deviceToken)
    }

    func createSession(goal: String, deviceToken: String) async throws -> GoalResponse {
        if deviceToken.isEmpty {
            throw MobileGatewayError.emptyToken
        }
        return try await post("/mobile/v1/sessions", body: GoalBody(goal: goal), token: deviceToken)
    }

    func timeline(sessionId: String, deviceToken: String) async throws -> SessionTimeline {
        if deviceToken.isEmpty {
            throw MobileGatewayError.emptyToken
        }
        return try await get("/mobile/v1/sessions/\(sessionId)/timeline", token: deviceToken)
    }

    func appendGoal(sessionId: String, text: String, deviceToken: String) async throws -> GoalResponse {
        if deviceToken.isEmpty {
            throw MobileGatewayError.emptyToken
        }
        return try await post("/mobile/v1/sessions/\(sessionId)/goals", body: GoalBody(goal: text), token: deviceToken)
    }

    func persistentAgents(deviceToken: String) async throws -> [PersistentAgent] {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        let response: PersistentAgentsResponse = try await get("/mobile/v1/agents/persistent", token: deviceToken)
        return response.agents
    }

    func createPersistentAgent(name: String, description: String, deviceToken: String) async throws -> PersistentAgent {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        return try await post("/mobile/v1/agents/persistent", body: AgentCreateBody(name: name, description: description), token: deviceToken)
    }

    func updatePersistentAgent(id: String, name: String?, description: String?, icon: String?, deviceToken: String) async throws -> PersistentAgent {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        return try await post("/mobile/v1/agents/persistent/\(id)", body: AgentUpdateBody(name: name, description: description, icon: icon), token: deviceToken)
    }

    func deletePersistentAgent(id: String, deviceToken: String) async throws {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        var request = try request(path: "/mobile/v1/agents/persistent/\(id)", method: "DELETE")
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        try await sendEmpty(request)
    }

    func agentMessages(agentId: String, deviceToken: String) async throws -> [PersistentAgentMessage] {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        let response: AgentMessagesResponse = try await get("/mobile/v1/agents/persistent/\(agentId)/messages", token: deviceToken)
        return response.messages
    }

    func sendAgentMessage(agentId: String, content: String, deviceToken: String) async throws -> AgentMessageResponse {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        return try await post("/mobile/v1/agents/persistent/\(agentId)/messages", body: AgentMessageBody(content: content), token: deviceToken, timeout: 180)
    }

    func cronJobs(deviceToken: String) async throws -> [CronJobInfo] {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        let response: CronJobsResponse = try await get("/mobile/v1/cron/jobs", token: deviceToken)
        return response.jobs
    }

    func approvals(deviceToken: String) async throws -> [ApprovalInfo] {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        let response: ApprovalsResponse = try await get("/mobile/v1/approvals", token: deviceToken)
        return response.approvals
    }

    func artifacts(deviceToken: String) async throws -> [ArtifactInfo] {
        if deviceToken.isEmpty { throw MobileGatewayError.emptyToken }
        let response: ArtifactsResponse = try await get("/mobile/v1/artifacts", token: deviceToken)
        return response.artifacts
    }

    private func get<T: Decodable>(_ path: String, token: String? = nil) async throws -> T {
        var request = try request(path: path, method: "GET")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await send(request)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, token: String? = nil, timeout: TimeInterval = 10) async throws -> T {
        var request = try request(path: path, method: "POST", timeout: timeout)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await send(request)
    }

    private func request(path: String, method: String, timeout: TimeInterval = 10) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw MobileGatewayError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw MobileGatewayError.badStatus(code)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func sendEmpty(_ request: URLRequest) async throws {
        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw MobileGatewayError.badStatus(code)
        }
    }
}

private struct EmptyBody: Encodable {}

private struct PairingCompleteBody: Encodable {
    let code: String
    let deviceName: String
    let platform: String
}

private struct GoalBody: Encodable {
    let goal: String
}

private struct AgentBody: Encodable {
    let name: String
    let baseUrl: String
}

private struct AgentCreateBody: Encodable {
    let name: String
    let description: String
}

private struct AgentUpdateBody: Encodable {
    let name: String?
    let description: String?
    let icon: String?
}

private struct AgentMessageBody: Encodable {
    let content: String
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

struct CronJobsResponse: Decodable {
    let jobs: [CronJobInfo]
}

struct ApprovalInfo: Decodable, Identifiable {
    let id: String
    let title: String
    let status: String
    let risk: String
    let summary: String
    let createdAt: String
}

struct ApprovalsResponse: Decodable {
    let approvals: [ApprovalInfo]
}

struct ArtifactInfo: Decodable, Identifiable {
    let id: String
    let title: String
    let kind: String
    let summary: String
    let createdAt: String
}

struct ArtifactsResponse: Decodable {
    let artifacts: [ArtifactInfo]
}
