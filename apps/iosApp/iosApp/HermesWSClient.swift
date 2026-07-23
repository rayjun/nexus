import Foundation

final class HermesWSClient: NSObject, ObservableObject {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private let baseURL: URL
    private var nextId = 0
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var eventHandlers: [(String, (Any) -> Void)] = []
    private var receiveLoop: Task<Void, Never>?
    private var pingTimer: Timer?

    @Published var isConnected = false

    init(baseURL: String) {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let wsScheme = normalized.hasPrefix("https") ? "wss" : "ws"
        if let url = URL(string: normalized) {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = wsScheme
            comps?.path = "/api/ws"
            self.baseURL = comps?.url ?? URL(string: "ws://127.0.0.1:8080/api/ws")!
        } else {
            self.baseURL = URL(string: "ws://127.0.0.1:8080/api/ws")!
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        let delegate = InsecureURLSessionDelegate()
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func connect(token: String) async throws {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let wsURL = comps.url else { throw URLError(.badURL) }

        task = session.webSocketTask(with: wsURL)
        task?.resume()

        let connected = try await waitForConnection()
        if !connected { throw URLError(.cannotConnectToHost) }

        await MainActor.run { self.isConnected = true }
        startReceiveLoop()
        startPing()
    }

    private func waitForConnection() async throws -> Bool {
        guard let task else { return false }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            task.sendPing { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: true)
                }
            }
        }
    }

    func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        DispatchQueue.main.async { self.isConnected = false }
    }

    // MARK: - RPC Call

    func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        let id = nextId
        nextId += 1
        let req: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: req)
        let msg = URLSessionWebSocketTask.Message.data(data)
        try await task?.send(msg)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            self.pending[id] = { result in
                switch result {
                case .success(let value): cont.resume(returning: value)
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Events

    func on(_ eventType: String, handler: @escaping (Any) -> Void) {
        eventHandlers.append((eventType, handler))
    }

    // MARK: - Private

    private func startReceiveLoop() {
        receiveLoop = Task {
            while !Task.isCancelled {
                do {
                    let msg = try await task?.receive()
                    switch msg {
                    case .data(let data):
                        handleData(data)
                    case .string(let str):
                        if let data = str.data(using: .utf8) {
                            handleData(data)
                        }
                    case .none:
                        break
                    @unknown default:
                        break
                    }
                } catch {
                    await MainActor.run { self.isConnected = false }
                    break
                }
            }
        }
    }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            self.task?.sendPing { _ in }
        }
    }

    private func handleData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = json["id"] as? Int {
            if let result = json["result"] {
                pending[id]?(.success(result))
            } else if let error = json["error"] {
                pending[id]?(.failure(NSError(domain: "HermesWS", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])))
            }
            pending.removeValue(forKey: id)
        }

        if let method = json["method"] as? String, method == "event" {
            if let params = json["params"] as? [String: Any], let type = params["type"] as? String {
                for (eventType, handler) in eventHandlers where eventType == type {
                    handler(params)
                }
            }
        }
    }
}