import Foundation
import Security
import os.log

private let wsLog = OSLog(subsystem: "com.rayjun.nexus", category: "HermesWS")

// Dedicated delegate that handles BOTH TLS trust challenges AND WebSocket lifecycle.
// Must conform to URLSessionDelegate (not just URLSessionWebSocketDelegate) for
// urlSession(_:didReceive:completionHandler:) to be called.
final class HermesWSDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate, URLSessionTaskDelegate {

    private func acceptServerTrust(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Add the server's own certificate as a trusted anchor
        if let serverCert = SecTrustGetCertificateAtIndex(trust, 0) {
            SecTrustSetAnchorCertificates(trust, [serverCert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }

        // Log eval result for debugging
        var error: CFError?
        let evaluated = SecTrustEvaluateWithError(trust, &error)
        os_log("delegate: trust for %{public}@ evaluated=%{public}@", log: wsLog, type: .info, challenge.protectionSpace.host, evaluated ? "true" : "false")
        if let error {
            os_log("delegate: trust eval error %{public}@", log: wsLog, type: .error, error.localizedDescription)
        }

        // Use .useCredential with the trust object — iOS will accept it since
        // we've set the server cert as an anchor
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        os_log("delegate: session-level challenge for %{public}@", log: wsLog, type: .info, challenge.protectionSpace.host)
        acceptServerTrust(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        os_log("delegate: task-level challenge for %{public}@", log: wsLog, type: .info, challenge.protectionSpace.host)
        acceptServerTrust(challenge, completionHandler: completionHandler)
    }

    var onOpen: (() -> Void)?
    var onClose: ((Int) -> Void)?
    var onError: ((Error) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        os_log("delegate: WS opened", log: wsLog, type: .info)
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        os_log("delegate: WS closed code=%d", log: wsLog, type: .error, Int(closeCode.rawValue))
        onClose?(Int(closeCode.rawValue))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            os_log("delegate: task error %{public}@", log: wsLog, type: .error, error.localizedDescription)
            onError?(error)
        }
    }
}

final class HermesWSClient: NSObject, ObservableObject {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private let wsURL: URL
    private var nextId = 0
    private let pendingLock = NSLock()
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var eventHandlers: [(String, (Any) -> Void)] = []
    private var pingTimer: Timer?
    private let wsDelegate = HermesWSDelegate()

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
        self.wsURL = comps?.url ?? URL(string: "wss://localhost/api/ws")!
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: wsDelegate, delegateQueue: nil)
    }

    func connect(token: String) async throws {
        guard var comps = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { throw URLError(.badURL) }

        os_log("connect: URL=%{public}@", log: wsLog, type: .info, url.absoluteString)

        // Wire delegate callbacks
        wsDelegate.onOpen = { [weak self] in
            DispatchQueue.main.async { self?.isConnected = true }
            self?.receiveNext()
        }
        wsDelegate.onClose = { [weak self] code in
            DispatchQueue.main.async { self?.isConnected = false }
        }
        wsDelegate.onError = { [weak self] _ in
            DispatchQueue.main.async { self?.isConnected = false }
        }

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        os_log("connect: task resumed", log: wsLog, type: .info)

        // Wait up to 15 seconds for isConnected
        for _ in 0..<150 {
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
                self.receiveNext()
            case .failure(let error):
                os_log("receive error: %{public}@", log: wsLog, type: .error, error.localizedDescription)
                DispatchQueue.main.async { self.isConnected = false }
            }
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