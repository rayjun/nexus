import Foundation
import os.log

private let wsLog = OSLog(subsystem: "com.rayjun.nexus", category: "HermesWS")

final class HermesWSClient: NSObject, ObservableObject {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private let wsURL: URL
    private var nextId = 0
    private let pendingLock = NSLock()
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var eventHandlers: [(String, (Any) -> Void)] = []
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
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect(token: String) async throws {
        guard var comps = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { throw URLError(.badURL) }

        os_log("connect: URL=%{public}@", log: wsLog, type: .info, url.absoluteString)

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        os_log("connect: task resumed", log: wsLog, type: .info)

        // Wait up to 10 seconds for isConnected
        for _ in 0..<100 {
            if self.isConnected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        if !self.isConnected {
            os_log("connect: timeout", log: wsLog, type: .error)
            throw URLError(.timedOut)
        }

        startPing()
        os_log("connect: success", log: wsLog, type: .info)
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        DispatchQueue.main.async { self.isConnected = false }
    }

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
        let str = String(data: data, encoding: .utf8) ?? "{}"
        let msg = URLSessionWebSocketTask.Message.string(str)
        os_log("call: method=%{public}@ id=%d", log: wsLog, type: .info, method, id)
        try await task?.send(msg)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            pendingLock.lock()
            pending[id] = { result in
                switch result {
                case .success(let value):
                    os_log("call: success id=%d", log: wsLog, type: .info, id)
                    cont.resume(returning: value)
                case .failure(let error):
                    os_log("call: error id=%d", log: wsLog, type: .error, id, error.localizedDescription)
                    cont.resume(throwing: error)
                }
            }
            pendingLock.unlock()
        }
    }

    func on(_ eventType: String, handler: @escaping (Any) -> Void) {
        eventHandlers.append((eventType, handler))
    }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.task?.sendPing { _ in }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let method = json["method"] as? String, method == "event" {
            if let params = json["params"] as? [String: Any], let type = params["type"] as? String {
                os_log("event: %{public}@", log: wsLog, type: .info, type)
                if type == "gateway.ready" {
                    DispatchQueue.main.async { self.isConnected = true }
                }
                for (eventType, handler) in eventHandlers where eventType == type {
                    handler(params)
                }
            }
        }

        if let id = (json["id"] as? NSNumber)?.intValue {
            os_log("rpc response: id=%d", log: wsLog, type: .info, id)
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
    }
}

extension HermesWSClient: URLSessionWebSocketDelegate, URLSessionDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        os_log("delegate: WS opened", log: wsLog, type: .info)
        // Start receiving messages via delegate
        receiveNext()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        os_log("delegate: WS closed code=%d", log: wsLog, type: .error, Int(closeCode.rawValue))
        DispatchQueue.main.async { self.isConnected = false }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        os_log("delegate: accepting self-signed cert for %{public}@", log: wsLog, type: .info, challenge.protectionSpace.host)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func receiveNext() {
        guard let task = self.task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
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
                // Continue receiving
                self.receiveNext()
            case .failure(let error):
                os_log("receive error: %{public}@", log: wsLog, type: .error, error.localizedDescription)
                DispatchQueue.main.async { self.isConnected = false }
            }
        }
    }
}