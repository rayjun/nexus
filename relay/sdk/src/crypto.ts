/**
 * E2E crypto layer for Nexus — TypeScript port of relay/crypto.py.
 *
 * X25519 key agreement + ChaCha20-Poly1305 AEAD + HKDF-SHA256.
 * MUST stay byte-for-byte compatible with:
 *   - relay/crypto.py    (Hermes Agent, Python, pynacl)
 *   - E2ECrypto.swift    (Nexus App, Swift, CryptoKit)
 *
 * Zero runtime npm dependencies: WebCrypto (X25519) + node:crypto
 * (chacha20-poly1305, hkdf) only.
 */

import {
  createCipheriv,
  createDecipheriv,
  createPrivateKey,
  createPublicKey,
  hkdfSync,
  createHash,
} from "node:crypto";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const subtle: any = (globalThis as any).crypto?.subtle;

export const HKDF_SALT = Buffer.from("nexus-e2e");
export const HKDF_INFO = Buffer.from("chachapoly-key");
export const KEY_SIZE = 32;
export const NONCE_SIZE = 12; // chacha20poly1305_ietf_NPUBBYTES
const TAG_SIZE = 16;

function requireSubtle(): any {
  if (!subtle) throw new Error("WebCrypto unavailable (Node >= 22 required)");
  return subtle;
}

// ── HKDF-SHA256 ──────────────────────────────────────────────────────────

/**
 * RFC 5869 HKDF-SHA256. Matches crypto.py's stdlib implementation and
 * CryptoKit's HKDF output byte-for-byte for the same salt/info/length.
 */
export function hkdfSha256(
  ikm: Uint8Array,
  length: number,
  salt: Uint8Array,
  info: Uint8Array,
): Buffer {
  return Buffer.from(hkdfSync("sha256", ikm, salt, info, length) as ArrayBuffer);
}

// ── Key pair ─────────────────────────────────────────────────────────────

export class KeyPair {
  /** Raw private scalar (32 bytes). */
  readonly privateBytes: Uint8Array;
  /** Raw public key (32 bytes). */
  readonly publicBytes: Uint8Array;

  private constructor(privateBytes: Uint8Array, publicBytes: Uint8Array) {
    this.privateBytes = privateBytes;
    this.publicBytes = publicBytes;
  }

  static async generate(): Promise<KeyPair> {
    const kp = await requireSubtle().generateKey(
      { name: "X25519" } as Algorithm,
      true,
      ["deriveBits"],
    );
    const pub = new Uint8Array(await requireSubtle().exportKey("raw", kp.publicKey));
    const jwk = await requireSubtle().exportKey("jwk", kp.privateKey);
    const d = jwk?.d ?? "";
    return new KeyPair(Buffer.from(d, "base64url"), pub);
  }

  static async fromPrivateBytes(raw: Uint8Array): Promise<KeyPair> {
    const privDer = Buffer.concat([
      Buffer.from("302e020100300506032b656e04220420", "hex"),
      Buffer.from(raw),
    ]);
    const priv = createPrivateKey({ key: privDer, format: "der", type: "pkcs8" });
    const spki = createPublicKey(priv).export({ format: "der", type: "spki" });
    // SPKI tail = 32-byte raw X25519 public key (matches pynacl / Swift).
    const pubRaw = Buffer.from(spki.subarray(spki.length - 32));
    const jwk: JsonWebKey = {
      kty: "OKP",
      crv: "X25519",
      d: Buffer.from(raw).toString("base64url"),
      x: pubRaw.toString("base64url"),
    };
    // Import once to validate + enable deriveBits later.
    await requireSubtle().importKey(
      "jwk",
      jwk,
      { name: "X25519" } as Algorithm,
      false,
      ["deriveBits"],
    );
    return new KeyPair(raw, pubRaw);
  }

  async deriveSharedSecret(peerPublic: Uint8Array): Promise<Uint8Array> {
    const jwk: JsonWebKey = {
      kty: "OKP",
      crv: "X25519",
      d: Buffer.from(this.privateBytes).toString("base64url"),
      x: Buffer.from(this.publicBytes).toString("base64url"),
    };
    const privKey = await requireSubtle().importKey(
      "jwk",
      jwk,
      { name: "X25519" } as Algorithm,
      false,
      ["deriveBits"],
    );
    const peerPub = await requireSubtle().importKey(
      "raw",
      peerPublic,
      { name: "X25519" } as Algorithm,
      false,
      [],
    );
    const bits = await requireSubtle().deriveBits(
      { name: "X25519", public: peerPub } as Algorithm,
      privKey,
      256,
    );
    return new Uint8Array(bits);
  }
}

// ── Shared secret / key derivation ───────────────────────────────────────

/**
 * Raw X25519 shared secret (matches Swift `sharedSecretFromKeyAgreement`).
 * When `psk` is given (the pairing code), the raw ECDH output is blinded:
 * final = HKDF(raw_ecdh, salt=psk, info="chachapoly-psk-blend") — binds the
 * agreement to knowledge of the pairing code (defeats pubkey-substitution
 * MITM by the relay or an on-path attacker).
 */
export async function computeSharedSecret(
  myPrivate: Uint8Array,
  peerPublic: Uint8Array,
  psk: Uint8Array | null = null,
): Promise<Uint8Array> {
  const kp = await KeyPair.fromPrivateBytes(myPrivate);
  const raw = await kp.deriveSharedSecret(peerPublic);
  if (psk !== null) {
    return hkdfSha256(raw, KEY_SIZE, psk, Buffer.from("chachapoly-psk-blend"));
  }
  return raw;
}

/**
 * Derive a ChaChaPoly key from the ECDH shared secret.
 * `direction` must be distinct per sender ("agent_to_app" | "app_to_agent")
 * — otherwise both sides derive the same key and both counters start at 0,
 * reusing key+nonce (keystream reuse breaks E2E entirely).
 */
export function deriveEncKey(sharedSecret: Uint8Array, direction = ""): Buffer {
  const info = direction
    ? Buffer.concat([HKDF_INFO, Buffer.from("-"), Buffer.from(direction)])
    : HKDF_INFO;
  return hkdfSha256(sharedSecret, KEY_SIZE, HKDF_SALT, info);
}

// ── Nonce / cipher ───────────────────────────────────────────────────────

/**
 * 4-byte big-endian sequence + first 8 bytes of the channel id hex.
 * Matches crypto.py make_nonce (channel_id.ljust(16,"0")[:16] → hex → 8B).
 */
export function makeNonce(sequence: number, channelId: string): Buffer {
  if (sequence >= 0xffffffff) {
    throw new RangeError(`sequence ${sequence} exceeds 32-bit nonce space`);
  }
  const seqBytes = Buffer.alloc(4);
  seqBytes.writeUInt32BE(sequence >>> 0, 0);
  const chBytes = Buffer.from(channelId.padEnd(16, "0").slice(0, 16), "hex");
  return Buffer.concat([seqBytes, chBytes.subarray(0, 8)]);
}

/** ChaCha20-Poly1305 (IETF) encrypt → base64(nonce || ct || tag). */
export function encrypt(
  plaintext: Uint8Array,
  key: Uint8Array,
  sequence: number,
  channelId: string,
): string {
  const nonce = makeNonce(sequence, channelId);
  const cipher = createCipheriv("chacha20-poly1305", key, nonce);
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([nonce, ct, tag]).toString("base64");
}

/** Decrypt base64(nonce || ct || tag); returns plaintext. */
export function decrypt(wirePayload: string, key: Uint8Array): Buffer {
  const raw = Buffer.from(wirePayload, "base64");
  const nonce = raw.subarray(0, NONCE_SIZE);
  const tag = raw.subarray(raw.length - TAG_SIZE);
  const ct = raw.subarray(NONCE_SIZE, raw.length - TAG_SIZE);
  const decipher = createDecipheriv("chacha20-poly1305", key, nonce);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ct), decipher.final()]);
}

/** Decrypt and return { sequence, plaintext } for replay validation. */
export function decryptWithSeq(
  wirePayload: string,
  key: Uint8Array,
): { sequence: number; plaintext: Buffer } {
  const raw = Buffer.from(wirePayload, "base64");
  const seq = raw.readUInt32BE(0);
  return { sequence: seq, plaintext: decrypt(wirePayload, key) };
}

export function encryptJsonRpc(
  rpc: Record<string, unknown>,
  key: Uint8Array,
  sequence: number,
  channelId: string,
): string {
  return encrypt(Buffer.from(JSON.stringify(rpc), "utf-8"), key, sequence, channelId);
}

export function decryptJsonRpc(
  wirePayload: string,
  key: Uint8Array,
): Record<string, unknown> {
  return JSON.parse(decrypt(wirePayload, key).toString("utf-8"));
}

/** 16-hex-char channel id: first 8 bytes of SHA-256(pairing code). */
export function channelIdFromPairingCode(code: string): string {
  return createHash("sha256").update(code, "utf-8").digest("hex").slice(0, 16);
}