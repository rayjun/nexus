"""E2E crypto layer for Nexus mobile communication.

X25519 key agreement + ChaCha20-Poly1305 AEAD encryption.
Used by both Hermes Agent (Python) and Nexus App (Swift, via E2ECrypto.swift).

Dependencies: pynacl (X25519, ChaCha20-Poly1305). HKDF-SHA256 is implemented
with the standard library (hashlib + hmac) to keep the dependency surface
minimal and avoid cryptography package ABI issues across Python versions.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import struct
from pathlib import Path
from typing import Optional

from nacl.bindings import (
    crypto_box_beforenm,
    crypto_aead_chacha20poly1305_ietf_encrypt,
    crypto_aead_chacha20poly1305_ietf_decrypt,
    crypto_aead_chacha20poly1305_ietf_NPUBBYTES,
)
from nacl.public import PrivateKey, PublicKey


def _hkdf_sha256(ikm: bytes, length: int, salt: bytes, info: bytes) -> bytes:
    """RFC 5869 HKDF-SHA256 using only the standard library.

    Matches cryptography.hazmat HKDF output byte-for-byte for the same
    salt/info/length (used by the Swift side via CryptoKit).
    """
    if not salt:
        salt = bytes(hashlib.sha256().digest_size)
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out = b""
    t = b""
    counter = 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        out += t
        counter += 1
    return out[:length]


HKDF_SALT = b"nexus-e2e"
HKDF_INFO = b"chachapoly-key"
KEY_SIZE = 32
NONCE_SIZE = 12  # crypto_aead_chacha20poly1305_ietf_NPUBBYTES


class KeyPair:
    def __init__(self, private_key: Optional[PrivateKey] = None) -> None:
        if private_key is None:
            private_key = PrivateKey.generate()
        self._priv = private_key

    @property
    def private_bytes(self) -> bytes:
        return bytes(self._priv)

    @property
    def public_bytes(self) -> bytes:
        return bytes(self._priv.public_key)

    @classmethod
    def from_private_bytes(cls, raw: bytes) -> "KeyPair":
        return cls(PrivateKey(raw))

    @classmethod
    def load(cls, path: Path) -> "KeyPair":
        raw = path.read_bytes()
        priv = raw[:32]
        return cls.from_private_bytes(priv)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.private_bytes + self.public_bytes)
        os.chmod(path, 0o600)


def derive_enc_key(shared_secret: bytes, direction: str = "") -> bytes:
    """Derive a ChaChaPoly key from the ECDH shared secret.

    `direction` must be distinct per sender: "agent_to_app" or "app_to_agent".
    Without direction separation, both sides derive the same key and both
    counters start at 0 — the first message in each direction would reuse
    key+nonce (ChaCha20 keystream reuse breaks E2E entirely).
    """
    info = HKDF_INFO
    if direction:
        info = HKDF_INFO + b"-" + direction.encode("utf-8")
    return _hkdf_sha256(shared_secret, KEY_SIZE, HKDF_SALT, info)


def compute_shared_secret(my_priv: bytes, peer_pub: bytes) -> bytes:
    return crypto_box_beforenm(bytes(PublicKey(peer_pub)), bytes(PrivateKey(my_priv)))


def make_nonce(sequence: int, channel_id: str) -> bytes:
    seq_bytes = struct.pack(">I", sequence)
    ch_bytes = bytes.fromhex(channel_id.ljust(16, "0")[:16])
    return seq_bytes + ch_bytes[:8]


def encrypt(plaintext: bytes, key: bytes, sequence: int, channel_id: str) -> str:
    nonce = make_nonce(sequence, channel_id)
    ciphertext = crypto_aead_chacha20poly1305_ietf_encrypt(
        plaintext, None, nonce, key
    )
    return base64.b64encode(nonce + ciphertext).decode("ascii")


def decrypt(wire_payload: str, key: bytes) -> bytes:
    raw = base64.b64decode(wire_payload)
    nonce = raw[:NONCE_SIZE]
    ciphertext = raw[NONCE_SIZE:]
    return crypto_aead_chacha20poly1305_ietf_decrypt(ciphertext, None, nonce, key)


def decrypt_with_seq(wire_payload: str, key: bytes) -> tuple[int, bytes]:
    """Decrypt and return (sequence, plaintext) for replay validation."""
    raw = base64.b64decode(wire_payload)
    nonce = raw[:NONCE_SIZE]
    seq = struct.unpack(">I", nonce[:4])[0]
    ciphertext = raw[NONCE_SIZE:]
    plaintext = crypto_aead_chacha20poly1305_ietf_decrypt(ciphertext, None, nonce, key)
    return seq, plaintext


def encrypt_jsonrpc(rpc: dict, key: bytes, sequence: int, channel_id: str) -> str:
    plaintext = json.dumps(rpc, separators=(",", ":")).encode("utf-8")
    return encrypt(plaintext, key, sequence, channel_id)


def decrypt_jsonrpc(wire_payload: str, key: bytes) -> dict:
    plaintext = decrypt(wire_payload, key)
    return json.loads(plaintext)


def channel_id_from_pairing_code(code: str) -> str:
    return hashlib.sha256(code.encode("utf-8")).hexdigest()[:8]


def save_enc_key(path: Path, key: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(key)
    os.chmod(path, 0o600)


def load_enc_key(path: Path) -> bytes:
    return path.read_bytes()[:KEY_SIZE]


def save_peer_pubkey(path: Path, pubkey: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(pubkey)
    os.chmod(path, 0o600)


def load_peer_pubkey(path: Path) -> bytes:
    return path.read_bytes()[:KEY_SIZE]


def save_sequence(path: Path, seq: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(seq))


def load_sequence(path: Path) -> int:
    if not path.exists():
        return 0
    return int(path.read_text().strip())