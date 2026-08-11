import Foundation
import CryptoKit
import os.log

private let connLog = OSLog(subsystem: "com.rayjun.nexus", category: "RelayConn")

/// Per-server WebSocket connection: socket, E2E keys, sequence counters,
/// and the pending-RPC table. One instance per paired server.
final class ServerConnection: NSObject, URLSessionWebSocketDelegate {
    let profile: ServerProfile

    private(set) var isConnected = false
    private(set) var isPairingInProgress = false

    /// When false, onDisconnected() will NOT schedule an automatic reconnect
    /// (user-initiated disconnect / server removal).
    private var shouldReconnect = true
    /// Monotonic connection generation — stale callbacks from a previous
    /// session are ignored.
    private var connectionEpoch = 0

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var delegate: ConnDelegate?

    // E2E state
    private var channelID: String
    private var encKey = Data()
    private var sendKey = Data()
    private var recvKey = Data()
    private var sendSeq: UInt32 = 0
    private var recvSeq: UInt32 = 0
    private var keyPairPriv = Data()
    private var keyPairPub = Data()
    /// Pairing code used as PSK during first-time key exchange (nil after).
    private var pairingPSK: Data?

    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private let lock = NSLock()

    var onStatusChange: (() -> Void)?
    /// Called when first-time pairing fails (timeout / key exchange error).
    var onPairingFailure: ((String) -> Void)?

    /// Pairing watchdog — 25s to complete key exchange or fail.
    private var pairingTimer: DispatchSourceTimer?

    // MARK: - Init

    init(profile: ServerProfile) {
        self.profile = profile
        self.channelID = profile.channelID
        super.init()
        loadKeys()
    }

    private func keychainPrefix() -> String { "srv_\(profile.id)" }

    private func loadKeys() {
        let enc = KeychainHelper.load(key: "\(keychainPrefix())_enc")
        let priv = KeychainHelper.load(key: "\(keychainPrefix())_priv")
        guard !enc.isEmpty, !priv.isEmpty else { return }
        encKey = Data(base64Encoded: enc) ?? Data()
        keyPairPriv = Data(base64Encoded: priv) ?? Data()
        if !keyPairPriv.isEmpty,
           let privKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyPairPriv) {
            keyPairPub = Data(privKey.publicKey.rawRepresentation)
        }
        if let keys = E2ECrypto.deriveDirectionalKeys(sharedSecret: encKey) {
            sendKey = keys.appToAgent
            recvKey = keys.agentToApp
        }
        if let s = UInt32(KeychainHelper.load(key: "\(keychainPrefix())_send")) { sendSeq = s }
        if let r = UInt32(KeychainHelper.load(key: "\(keychainPrefix())_recv")) { recvSeq = r }
    }

    private func persistKeys() {
        KeychainHelper.save(encKey.base64EncodedString(), key: "\(keychainPrefix())_enc")
        KeychainHelper.save(keyPairPriv.base64EncodedString(), key: "\(keychainPrefix())_priv")
        KeychainHelper.save(String(sendSeq), key: "\(keychainPrefix())_send")
        KeychainHelper.save(String(recvSeq), key: "\(keychainPrefix())_recv")
    }

    func clearKeys() {
        for k in ["_enc", "_priv", "_send", "_recv"] {
            KeychainHelper.delete(key: "\(keychainPrefix())\(k)")
        }
    }

    // MARK: - Connection

    func connect() {
        guard !isConnected, !isPairingInProgress else { return }
        shouldReconnect = true
        let epoch = connectionEpoch + 1
        connectionEpoch = epoch
        // Release any previous session/delegate before creating a new one —
        // URLSession strongly retains its delegate; leaking old sessions on
        // every reconnect would accumulate memory.
        if let old = session {
            old.invalidateAndCancel()
        }
        session = nil
        delegate = nil
        log("connecting: %@", profile.relayURL)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let d = ConnDelegate()
        d.onOpen = { [weak self] in self?.onConnected(epoch: epoch) }
        d.onClose = { [weak self] in self?.onDisconnected(epoch: epoch) }
        d.onMessage = { [weak self] msg in self?.handleMessage(msg) }
        delegate = d
        session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        guard let url = URL(string: profile.relayURL) else {
            // Invalid URL — surface it instead of silently staying disconnected.
            log("invalid relay URL: %@", profile.relayURL)
            isConnected = false
            onStatusChange?()
            return
        }
        task = session.webSocketTask(with: url)
        task?.resume()
        receiveLoop(epoch: epoch)
    }

    func disconnect() {
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        isConnected = false
    }

    private func onConnected(epoch: Int) {
        guard epoch == connectionEpoch else { return }  // stale session
        log("relay connected: %@", profile.relayURL)
        sendSeq = 0
        recvSeq = 0
        persistKeys()
        isConnected = true
        joinChannel()
        onStatusChange?()
    }

    private func onDisconnected(epoch: Int) {
        guard epoch == connectionEpoch else { return }  // stale session
        log("relay disconnected: %@", profile.relayURL)
        isConnected = false
        onStatusChange?()
        if shouldReconnect && !isPairingInProgress {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.shouldReconnect, self.connectionEpoch == epoch else { return }
                self.connect()
            }
        }
    }

    private func joinChannel() {
        send(["type": "join", "channel": channelID, "role": "app"])
    }

    // MARK: - Pairing (add server)

    /// First-time pairing: generates a fresh keypair and exchanges keys with
    /// the agent. On success the keys are persisted under this server's id.
    func startPairing(code: String) {
        isPairingInProgress = true
        pairingPSK = code.data(using: .utf8)
        let (priv, pub) = E2ECrypto.generateKeyPair()
        keyPairPriv = priv
        keyPairPub = pub
        channelID = E2ECrypto.channelIdFromPairingCode(code)
        startPairingTimer()
        connect()
    }

    private func startPairingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 25)
        timer.setEventHandler { [weak self] in
            guard let self, self.isPairingInProgress else { return }
            self.isPairingInProgress = false
            self.pairingTimer = nil
            self.log("pairing timed out (server %@)", self.profile.name)
            DispatchQueue.main.async {
                self.onPairingFailure?("Pairing timed out — is the agent running with this code?")
            }
        }
        timer.resume()
        pairingTimer = timer
    }

    private func cancelPairingTimer() {
        pairingTimer?.cancel()
        pairingTimer = nil
    }

    private func handlePaired() {
        log("paired event (channel %@)", channelID)
        if !encKey.isEmpty {
            // Already paired — reconnection
            log("reconnected, communication mode")
            onStatusChange?()
            NotificationCenter.default.post(name: NSNotification.Name("RelayPaired"), object: profile.id)
        } else {
            // First pairing — wait for agent public key
            isPairingInProgress = true
        }
    }

    private func handleAgentPublicKey(_ payload: String) {
        guard let agentPub = Data(base64Encoded: payload),
              let shared = E2ECrypto.computeSharedSecret(myPriv: keyPairPriv, peerPub: agentPub, psk: pairingPSK),
              let keys = E2ECrypto.deriveDirectionalKeys(sharedSecret: shared) else {
            log("pairing failed: key exchange error")
            isPairingInProgress = false
            cancelPairingTimer()
            DispatchQueue.main.async {
                self.onPairingFailure?("Key exchange failed — pairing code mismatch?")
            }
            return
        }
        encKey = shared
        sendKey = keys.appToAgent
        recvKey = keys.agentToApp
        sendSeq = 0
        recvSeq = 0
        persistKeys()
        isPairingInProgress = false
        cancelPairingTimer()
        pairingPSK = nil  // code consumed — no longer needed
        log("pairing complete (server %@)", profile.name)
        onStatusChange?()
        NotificationCenter.default.post(name: NSNotification.Name("RelayPaired"), object: profile.id)
    }

    // MARK: - Message handling

    private func handleMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "paired":
            handlePaired()
        case "data":
            let payload = msg["payload"] as? String ?? ""
            if encKey.isEmpty && isPairingInProgress {
                // pairing: this data is the agent's public key (plaintext)
                sendPublicKey()
                handleAgentPublicKey(payload)
            } else if !encKey.isEmpty, isPlaintextPublicKey(payload) {
                // Rekey: agent reconnected and sent a FRESH plaintext public
                // key. Respond with our own fresh key and re-derive session
                // keys so a new connection never reuses the old key+nonce
                // space (ChaCha20 keystream reuse protection).
                handleRekey(payload)
            } else if !encKey.isEmpty {
                handleEncryptedData(payload)
            }
        case "pong":
            break
        case "error":
            log("relay error: %@", msg["message"] as? String ?? "?")
        default:
            break
        }
    }

    /// A plaintext X25519 public key is exactly 32 raw bytes → 44 base64 chars.
    private func isPlaintextPublicKey(_ payload: String) -> Bool {
        guard payload.count == 44, let data = Data(base64Encoded: payload) else { return false }
        return data.count == 32
    }

    private func handleRekey(_ agentPubPayload: String) {
        guard let agentPub = Data(base64Encoded: agentPubPayload) else { return }
        // Generate a fresh ephemeral keypair and send its public key first
        let (priv, pub) = E2ECrypto.generateKeyPair()
        keyPairPriv = priv
        keyPairPub = pub
        sendPublicKey()

        guard let shared = E2ECrypto.computeSharedSecret(myPriv: keyPairPriv, peerPub: agentPub),
              let keys = E2ECrypto.deriveDirectionalKeys(sharedSecret: shared) else {
            log("rekey failed: key derivation error")
            return
        }
        encKey = shared
        sendKey = keys.appToAgent
        recvKey = keys.agentToApp
        sendSeq = 0
        recvSeq = 0
        persistKeys()
        log("rekey complete: fresh session keys derived")
        onStatusChange?()
        NotificationCenter.default.post(name: NSNotification.Name("RelayPaired"), object: profile.id)
    }

    private func sendPublicKey() {
        send(["type": "data", "channel": channelID, "payload": keyPairPub.base64EncodedString()])
    }

    private func handleEncryptedData(_ payload: String) {
        guard let (seq, rpc) = E2ECrypto.decryptJSONWithSeq(payload, key: recvKey) else {
            log("decrypt failed")
            return
        }
        guard seq == recvSeq else {
            log("replay/mismatch: got %d expected %d", Int(seq), Int(recvSeq))
            return
        }
        recvSeq += 1
        persistKeys()

        let method = rpc["method"] as? String ?? ""
        let id = rpc["id"]
        if method == "event" {
            let params = rpc["params"] as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("RelayEvent"),
                    object: self.profile.id,
                    userInfo: ["event": params["type"] as? String ?? "", "data": params]
                )
            }
        } else if let id = id as? Int {
            lock.lock()
            let cont = pending.removeValue(forKey: id)
            lock.unlock()
            cont?.resume(returning: rpc["result"] ?? [:])
        }
    }

    // MARK: - RPC

    /// Monotonic RPC id (avoids random collisions orphaning a caller).
    private var nextRPCID: Int = 1

    func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        // Fail fast on a dead connection instead of silently dropping + 30s wait.
        guard isConnected, task != nil else {
            throw NSError(domain: "Nexus", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "not connected"])
        }
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            let i = nextRPCID
            nextRPCID += 1
            return i
        }()
        let rpc: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]

        let seq: UInt32 = {
            lock.lock()
            defer { lock.unlock() }
            let s = sendSeq
            sendSeq += 1
            return s
        }()
        persistKeys()

        guard let wire = E2ECrypto.encryptJSON(rpc, key: sendKey, sequence: seq, channelId: channelID) else {
            throw NSError(domain: "Nexus", code: 1, userInfo: [NSLocalizedDescriptionKey: "encrypt failed"])
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            // Insert the continuation BEFORE sending — a fast response that
            // arrives between send and insert would otherwise be lost.
            lock.lock()
            pending[id] = cont
            lock.unlock()

            send(["type": "data", "channel": channelID, "payload": wire])
            log("rpc sent: %@ id=%d seq=%d", method, id, Int(seq))

            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let c = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                c?.resume(throwing: NSError(domain: "Nexus", code: 2,
                                            userInfo: [NSLocalizedDescriptionKey: "rpc timeout"]))
            }
        }
    }

    // MARK: - WebSocket plumbing

    private func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error { self.log("send error: %@", error.localizedDescription) }
        }
    }

    private func receiveLoop(epoch: Int) {
        task?.receive { [weak self] result in
            guard let self, self.connectionEpoch == epoch else { return }  // stale
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleMessage(json)
                    }
                case .data(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleMessage(json)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop(epoch: epoch)
            case .failure(let error):
                self.log("receive error: %@", error.localizedDescription)
                self.onDisconnected(epoch: epoch)
            }
        }
    }

    private func log(_ format: StaticString, _ args: CVarArg...) {
        os_log(format, log: connLog, type: .info, args)
    }
}

private final class ConnDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?()
    }
}
