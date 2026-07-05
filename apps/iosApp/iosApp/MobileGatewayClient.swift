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

    private func get<T: Decodable>(_ path: String, token: String? = nil) async throws -> T {
        var request = try request(path: path, method: "GET")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await send(request)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, token: String? = nil) async throws -> T {
        var request = try request(path: path, method: "POST")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await send(request)
    }

    private func request(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw MobileGatewayError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
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
