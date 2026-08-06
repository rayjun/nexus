import Foundation
import CryptoKit

enum E2ECrypto {
    static let hkdfSalt = "nexus-e2e".data(using: .utf8)!
    static let hkdfInfo = "chachapoly-key".data(using: .utf8)!
    static let keySize = 32
    static let nonceSize = 12

    static func generateKeyPair() -> (priv: Data, pub: Data) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return (Data(priv.rawRepresentation), Data(priv.publicKey.rawRepresentation))
    }

    static func computeSharedSecret(myPriv: Data, peerPub: Data) -> Data? {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myPriv),
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub) else {
            return nil
        }
        guard let shared = try? priv.sharedSecretFromKeyAgreement(with: pub) else {
            return nil
        }
        // IMPORTANT: return the RAW ECDH output, NOT an HKDF-derivation of it.
        // The Python side (crypto.py) computes raw ECDH then derives directional
        // keys with ONE HKDF pass (info="chachapoly-key-<dir>"). If we derived
        // here too, the keys would be double-HKDF'd and never match the agent.
        return shared.withUnsafeBytes { Data($0) }
    }

    /// Derive direction-separated ChaChaPoly keys from the ECDH shared secret.
    /// Direction separation is REQUIRED: without it both sides derive the same
    /// key and both counters start at 0 — the first message in each direction
    /// would reuse key+nonce, breaking ChaCha20 (keystream reuse).
    static func deriveDirectionalKeys(sharedSecret: Data) -> (agentToApp: Data, appToAgent: Data)? {
        guard sharedSecret.count == keySize else { return nil }
        let sym = SymmetricKey(data: sharedSecret)

        func derive(_ info: String) -> Data? {
            guard let infoData = ("chachapoly-key-" + info).data(using: .utf8) else { return nil }
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: sym,
                salt: hkdfSalt,
                info: infoData,
                outputByteCount: keySize
            )
            return derived.withUnsafeBytes { Data($0) }
        }

        guard let a2a = derive("agent_to_app"), let a2ag = derive("app_to_agent") else { return nil }
        return (a2a, a2ag)
    }

    static func encrypt(plaintext: Data, key: Data, sequence: UInt32, channelId: String) -> String? {
        guard key.count == keySize else { return nil }
        let symKey = SymmetricKey(data: key)
        var seqBytes = withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
        let chBytes = channelIdToBytes(channelId)
        let nonce = seqBytes + chBytes

        guard let chachaNonce = try? ChaChaPoly.Nonce(data: nonce),
              let sealed = try? ChaChaPoly.seal(plaintext, using: symKey, nonce: chachaNonce) else {
            return nil
        }
        let combined = nonce + sealed.ciphertext + sealed.tag
        return combined.base64EncodedString()
    }

    static func decrypt(wirePayload: String, key: Data) -> Data? {
        guard key.count == keySize else { return nil }
        guard let raw = Data(base64Encoded: wirePayload) else { return nil }
        guard raw.count > nonceSize else { return nil }
        let nonce = raw.prefix(nonceSize)
        let ciphertextWithTag = raw.suffix(from: nonceSize)
        let symKey = SymmetricKey(data: key)
        guard let chachaNonce = try? ChaChaPoly.Nonce(data: nonce),
              let sealed = try? ChaChaPoly.SealedBox(nonce: chachaNonce,
                                                      ciphertext: ciphertextWithTag.prefix(ciphertextWithTag.count - 16),
                                                      tag: ciphertextWithTag.suffix(16)) else {
            return nil
        }
        return try? ChaChaPoly.open(sealed, using: symKey)
    }

    static func encryptJSON(_ json: [String: Any], key: Data, sequence: UInt32, channelId: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return encrypt(plaintext: data, key: key, sequence: sequence, channelId: channelId)
    }

    static func decryptJSON(_ wirePayload: String, key: Data) -> [String: Any]? {
        guard let data = decrypt(wirePayload: wirePayload, key: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Decrypt and extract the sequence from the nonce for replay validation.
    static func decryptJSONWithSeq(_ wirePayload: String, key: Data) -> (seq: UInt32, json: [String: Any])? {
        guard let raw = Data(base64Encoded: wirePayload), raw.count >= nonceSize + 16 else { return nil }
        let seqBytes = raw.prefix(4)
        let seq = seqBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard let data = decrypt(wirePayload: wirePayload, key: key) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (seq, json)
    }

    static func channelIdFromPairingCode(_ code: String) -> String {
        let hash = SHA256.hash(data: code.data(using: .utf8)!)
        return hash.withUnsafeBytes { Data($0) }
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func channelIdToBytes(_ channelId: String) -> Data {
        var hex = channelId.padding(toLength: 16, withPad: "0", startingAt: 0)
        if hex.count > 16 { hex = String(hex.prefix(16)) }
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in stride(from: 0, to: 16, by: 2) {
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            if let byte = UInt8(hex[start..<end], radix: 16) {
                bytes[i / 2] = byte
            }
        }
        return Data(bytes)
    }
}