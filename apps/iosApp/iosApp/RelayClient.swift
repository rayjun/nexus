import Foundation
import CryptoKit
import os.log

private let relayLog = OSLog(subsystem: "com.rayjun.nexus", category: "Relay")

final class RelayClient: NSObject, ObservableObject {
    static let shared = RelayClient()

    @Published var isConnected = false
    @Published var isPaired = false
    @Published var pairingState: PairingState = .idle

    enum PairingState {
        case idle
        case connecting
        case waitingForAgent
        case exchangingKeys
        case paired
        case error(String)
    }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private let delegate = RelayWebSocketDelegate()

    private var channelID: String = ""
    private var encKey: Data = Data()      // shared secret (persisted)
    private var sendKey: Data = Data()     // app_to_agent (encrypt)
    private var recvKey: Data = Data()     // agent_to_app (decrypt)
    private var sendSeq: UInt32 = 0
    private var recvSeq: UInt32 = 0
    private var keyPairPriv: Data = Data()
    private var keyPairPub: Data = Data()

    /// The resolved relay URL (UserDefaults override, else platform default).
    var currentRelayURL: String { relayURL }

    /// C4: relay URL is configurable via UserDefaults (`relay_url`); DEBUG
    /// builds fall back to the local relay for simulator testing. Set
    /// `relay_url` to your deployed relay (e.g. wss://relay.example.com/relay).
    private var relayURL: String {
        if let configured = UserDefaults.standard.string(forKey: "relay_url"), !configured.isEmpty {
            return configured
        }
        #if DEBUG
        return "ws://127.0.0.1:9120"
        #else
        return "wss://relay.example.com/relay"
        #endif
    }

    override init() {
        super.init()
        delegate.onMessage = { [weak self] msg in
            self?.handleMessage(msg)
        }
        delegate.onOpen = { [weak self] in
            self?.onConnected()
        }
        delegate.onClose = { [weak self] in
            self?.onDisconnected()
        }
        loadPairedState()
    }

    // MARK: - State persistence

    private func loadPairedState() {
        #if DEBUG
        let udKey = UserDefaults.standard.string(forKey: "relay_enc_key") ?? ""
        let udChId = UserDefaults.standard.string(forKey: "relay_channel_id") ?? ""
        if !udKey.isEmpty && !udChId.isEmpty {
            encKey = Data(base64Encoded: udKey) ?? Data()
            channelID = udChId
            if let keys = E2ECrypto.deriveDirectionalKeys(sharedSecret: encKey) {
                sendKey = keys.appToAgent
                recvKey = keys.agentToApp
            }
            isPaired = true
            relayLog("loaded paired state from UserDefaults: channel=%@", udChId)
            return
        }
        #endif

        let key = KeychainHelper.load(key: "relay_enc_key")
        let chId = KeychainHelper.load(key: "relay_channel_id")
        if !key.isEmpty && !chId.isEmpty {
            encKey = Data(base64Encoded: key) ?? Data()
            channelID = chId
            if let keys = E2ECrypto.deriveDirectionalKeys(sharedSecret: encKey) {
                sendKey = keys.appToAgent
                recvKey = keys.agentToApp
            }
            // C2: restore persisted counters so nonces never repeat across restarts
            if let s = UInt32(KeychainHelper.load(key: "relay_send_seq")) { sendSeq = s }
            if let r = UInt32(KeychainHelper.load(key: "relay_recv_seq")) { recvSeq = r }
            isPaired = true
            relayLog("loaded paired state: channel=%@ seq=%d/%d", chId, sendSeq, recvSeq)
        }
    }

    private func persistCounters() {
        KeychainHelper.save(String(sendSeq), key: "relay_send_seq")
        KeychainHelper.save(String(recvSeq), key: "relay_recv_seq")
    }

    // MARK: - Connection

    func connect() {
        guard isPaired else { return }
        relayLog("connecting to relay: %@", relayURL)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        guard let url = URL(string: relayURL) else { return }
        task = session.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    private func onConnected() {
        relayLog("relay connected")
        // New connection = new session: reset counters so nonces restart at 0
        // on both ends. Replay protection still works within the session.
        sendSeq = 0
        recvSeq = 0
        persistCounters()
        isConnected = true
        joinChannel()
    }

    private func onDisconnected() {
        relayLog("relay disconnected")
        isConnected = false
        if isPaired {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.connect()
            }
        }
    }

    private func joinChannel() {
        send(["type": "join", "channel": channelID, "role": "app"])
    }

    // MARK: - Pairing

    func pair(withCode code: String) {
        DispatchQueue.main.async { self.pairingState = .connecting }

        let (priv, pub) = E2ECrypto.generateKeyPair()
        keyPairPriv = priv
        keyPairPub = pub
        channelID = E2ECrypto.channelIdFromPairingCode(code)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        guard let url = URL(string: relayURL) else {
            DispatchQueue.main.async { self.pairingState = .error("bad relay URL") }
            return
        }
        task = session.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
    }

    private func handlePaired() {
        relayLog("paired event from relay")
        if isPaired {
            // Already paired — relay confirms both endpoints are in the channel,
            // so communication can start now.
            relayLog("reconnected, entering communication mode")
            DispatchQueue.main.async {
                self.pairingState = .paired
                // Signal ContentView to (re)load home data once the peer is present
                NotificationCenter.default.post(
                    name: NSNotification.Name("RelayPaired"),
                    object: nil
                )
            }
        } else {
            // First-time pairing — wait for agent's public key
            DispatchQueue.main.async { self.pairingState = .waitingForAgent }
        }
    }

    private func sendPublicKey() {
        let payload = keyPairPub.base64EncodedString()
        send(["type": "data", "channel": channelID, "payload": payload])
        relayLog("sent public key to agent")
    }

    private func handleAgentPublicKey(_ payload: String) {
        DispatchQueue.main.async { self.pairingState = .exchangingKeys }

        guard let agentPub = Data(base64Encoded: payload) else {
            DispatchQueue.main.async { self.pairingState = .error("bad agent pubkey") }
            return
        }

        guard let shared = E2ECrypto.computeSharedSecret(myPriv: keyPairPriv, peerPub: agentPub) else {
            DispatchQueue.main.async { self.pairingState = .error("ECDH failed") }
            return
        }
        guard let keys = E2ECrypto.deriveDirectionalKeys(sharedSecret: shared) else {
            DispatchQueue.main.async { self.pairingState = .error("key derivation failed") }
            return
        }

        encKey = shared
        sendKey = keys.appToAgent
        recvKey = keys.agentToApp
        sendSeq = 0
        recvSeq = 0

        KeychainHelper.save(encKey.base64EncodedString(), key: "relay_enc_key")
        KeychainHelper.save(channelID, key: "relay_channel_id")
        KeychainHelper.save(keyPairPriv.base64EncodedString(), key: "relay_priv_key")
        persistCounters()

        DispatchQueue.main.async { self.pairingState = .paired }
        isPaired = true
        relayLog("pairing complete, enc_key established")
    }

    // MARK: - Message handling

    private func handleMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        switch type {
        case "paired":
            handlePaired()
            // Agent will send its public key next
        case "data":
            let payload = msg["payload"] as? String ?? ""

            if !isPaired, case .waitingForAgent = pairingState {
                // First-time pairing: this data is the agent's public key (plaintext)
                sendPublicKey()
                handleAgentPublicKey(payload)
            } else if isPaired {
                // Already paired: all data is encrypted JSON-RPC
                handleEncryptedData(payload)
            } else if case .paired = pairingState {
                // First-time pairing: first encrypted message is the paired confirmation
                if let (seq, rpc) = E2ECrypto.decryptJSONWithSeq(payload, key: recvKey),
                   seq == recvSeq {
                    if let params = rpc["params"] as? [String: Any],
                       params["type"] as? String == "paired" {
                        relayLog("pairing verified ✓")
                        recvSeq += 1
                        persistCounters()
                    }
                }
            }
        case "pong":
            break
        case "error":
            let message = msg["message"] as? String ?? "unknown error"
            relayLog("relay error: %@", message)
            if case .connecting = pairingState {
                DispatchQueue.main.async { self.pairingState = .error(message) }
            }
        default:
            break
        }
    }

    private func handleEncryptedData(_ payload: String) {
        guard let (seq, rpc) = E2ECrypto.decryptJSONWithSeq(payload, key: recvKey) else {
            relayLog("decrypt failed")
            return
        }

        // H4: reject replays — incoming seq must equal expected recv_seq
        guard seq == recvSeq else {
            relayLog("replay/mismatch: got seq=%d expected=%d — dropping", Int(seq), Int(recvSeq))
            return
        }

        recvSeq += 1
        persistCounters()

        let method = rpc["method"] as? String ?? ""
        let id = rpc["id"]

        relayLog("rpc received: method=%@ id=%@", method, String(describing: id ?? ""))

        if method == "event" {
            let params = rpc["params"] as? [String: Any] ?? [:]
            let eventType = params["type"] as? String ?? ""
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("RelayEvent"),
                    object: nil,
                    userInfo: ["event": eventType, "data": params]
                )
            }
        } else if let id = id as? Int {
            pendingLock.lock()
            let cont = pending.removeValue(forKey: id)
            pendingLock.unlock()
            cont?.resume(returning: rpc["result"] ?? [:])
        }
    }

    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private let pendingLock = NSLock()

    // MARK: - RPC

    func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        let id = Int.random(in: 1...999999)
        let rpc: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        // H6: allocate sendSeq under lock to avoid concurrent nonce reuse
        let seq: UInt32 = {
            pendingLock.lock()
            defer { pendingLock.unlock() }
            let s = sendSeq
            sendSeq += 1
            return s
        }()
        persistCounters()

        guard let wire = E2ECrypto.encryptJSON(rpc, key: sendKey, sequence: seq, channelId: channelID) else {
            throw NSError(domain: "Nexus", code: 1, userInfo: [NSLocalizedDescriptionKey: "encrypt failed"])
        }

        send(["type": "data", "channel": channelID, "payload": wire])
        relayLog("rpc sent: method=%@ id=%d seq=%d", method, id, Int(seq))

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            pendingLock.lock()
            pending[id] = cont
            pendingLock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                self.pendingLock.lock()
                let cont = self.pending.removeValue(forKey: id)
                self.pendingLock.unlock()
                cont?.resume(throwing: NSError(domain: "Nexus", code: 2, userInfo: [NSLocalizedDescriptionKey: "rpc timeout"]))
            }
        }
    }

    // MARK: - WebSocket

    private func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error = error {
                relayLog("send error: %@", error.localizedDescription)
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self?.handleMessage(json)
                    }
                case .data(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self?.handleMessage(json)
                    }
                @unknown default:
                    break
                }
                self?.receiveLoop()
            case .failure(let error):
                relayLog("receive error: %@", error.localizedDescription)
                self?.onDisconnected()
            }
        }
    }
}

// MARK: - WebSocket Delegate

final class RelayWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        relayLog("WS opened")
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        relayLog("WS closed: %d", closeCode.rawValue)
        onClose?()
    }
}

private func relayLog(_ format: StaticString, _ args: CVarArg...) {
    os_log(format, log: relayLog, type: .info, args)
}