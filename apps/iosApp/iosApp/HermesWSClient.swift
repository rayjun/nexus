import Foundation

final class HermesWSClient: NSObject, ObservableObject {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private let wsURL: URL
    private var nextId = 0
    private let pendingLock = NSLock()
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var eventHandlers: [(String, (Any) -> Void)] = []
    private var receiveTask: Task<Void, Never>?
    private var pingTimer: Timer?

    @Published var isConnected = false

    init(baseURL: String) {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let wsScheme = normalized.hasPrefix("https") ? "wss" : "ws"
        var comps: URLComponents? = nil
        if let url = URL(string: normalized) {
            comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = wsScheme
            comps?.path = "/api/ws"
        }
        self.wsURL = comps?.url ?? URL(string: "ws://127.0.0.1:8080/api/ws")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        let delegate = InsecureURLSessionDelegate()
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func connect(token: String) async throws {
        guard var comps = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { throw URLError(.badURL) }

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // Start receive loop before waiting
        startReceiveLoop()
        startPing()

        // Give WS 3 seconds to connect; if it closes in that time, it's an auth/network failure
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // If closeCode is still .invalid, the WS is open (no close happened)
        if task.closeCode != .invalid {
            throw URLError(.cannotConnectToHost)
        }

        await MainActor.run { self.isConnected = true }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
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
            pendingLock.lock()
            pending[id] = { result in
                switch result {
                case .success(let value): cont.resume(returning: value)
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            pendingLock.unlock()
        }
    }

    // MARK: - Events

    func on(_ eventType: String, handler: @escaping (Any) -> Void) {
        eventHandlers.append((eventType, handler))
    }

    // MARK: - Private

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = self.task else { break }
                    let msg = try await task.receive()
                    switch msg {
                    case .data(let data):
                        self.handleMessage(data)
                    case .string(let str):
                        if let data = str.data(using: .utf8) {
                            self.handleMessage(data)
                        }
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
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.task?.sendPing { _ in }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Handle RPC response (has "id" field)
        if let id = (json["id"] as? NSNumber)?.intValue ?? (json["id"] as? Int) {
            pendingLock.lock()
            let handler = pending.removeValue(forKey: id)
            pendingLock.unlock()
            if let handler {
                if let result = json["result"] {
                    handler(.success(result))
                } else if let error = json["error"] {
                    handler(.failure(NSError(domain: "HermesWS", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])))
                }
            }
        }

        // Handle event (has "method": "event")
        if let method = json["method"] as? String, method == "event" {
            if let params = json["params"] as? [String: Any], let type = params["type"] as? String {
                for (eventType, handler) in eventHandlers where eventType == type {
                    handler(params)
                }
            }
        }
    }
}