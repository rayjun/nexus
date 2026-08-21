/**
 * @nexus/relay-sdk — E2E crypto + relay protocol primitives for TypeScript.
 *
 * Zero-dependency: Node >= 22 built-ins only (WebCrypto for X25519,
 * node:crypto for ChaCha20-Poly1305 + HKDF-SHA256).
 */
export {
  HKDF_SALT,
  HKDF_INFO,
  KEY_SIZE,
  NONCE_SIZE,
  hkdfSha256,
  KeyPair,
  computeSharedSecret,
  deriveEncKey,
  makeNonce,
  encrypt,
  decrypt,
  decryptWithSeq,
  encryptJsonRpc,
  decryptJsonRpc,
  channelIdFromPairingCode,
} from "./crypto.js";