# Nexus Mobile Relay — Implementation Plan

## Overview

Replace the current direct-WSS-to-Dashboard connection with a Relay-based E2E encrypted architecture. Users pair with a 6-digit code; all subsequent communication is encrypted with X25519 + ChaCha20-Poly1305 and relayed through a lightweight public server. No domains, certificates, tokens, or port configuration needed on the user's machine.

## Architecture

```
┌──────────────┐     WSS (outbound)    ┌──────────┐     WSS (outbound)    ┌──────────────┐
│ Hermes Agent │ ←──────────────────→  │  Relay   │  ←──────────────────→  │  Nexus App   │
│ (user server)│   E2E encrypted      │ (public)  │   E2E encrypted       │ (iOS/Android) │
└──────────────┘                      └──────────┘                      └──────────────┘
```

- **Hermes Agent**: runs on user's server, connects outbound to Relay, opens no inbound ports
- **Relay Server**: public server with trusted TLS (Caddy + Let's Encrypt), routes encrypted bytes between paired endpoints
- **Nexus App**: phone side, connects outbound to Relay

## Components

### 1. Relay Server (`relay_server.py`)

**Location**: jp-lighthouse, listens on `127.0.0.1:9120`, Caddy reverse-proxies `wss://erc8004list.xyz/relay`

**Responsibilities**:
- Accept WebSocket connections from Agents and Apps
- Match endpoints by `channel_id` (SHA-256 hash of pairing code, first 8 bytes hex)
- Forward encrypted `data` messages between paired endpoints without parsing
- Notify both sides with `paired` event when both endpoints join
- Heartbeat/ping every 30s, drop dead connections after 90s

**Relay protocol (plaintext, Relay-visible)**:
```json
{"type": "join", "channel": "a1b2c3d4", "role": "agent"}
{"type": "data", "channel": "a1b2c3d4", "payload": "base64(E2E encrypted bytes)"}
{"type": "paired", "channel": "a1b2c3d4"}
```

**Does NOT**:
- Parse message content
- Store messages (forward and discard)
- Understand JSON-RPC
- Know Agent or App protocol

**Estimated**: ~200 lines Python, using `websockets` + `asyncio`

### 2. E2E Crypto Layer

**Algorithm**:
- Key agreement: X25519 ECDH
- Encryption: ChaCha20-Poly1305 AEAD
- Key derivation: HKDF-SHA256
- Nonce: 12 bytes = 4-byte sequence (big-endian) + 8-byte channel_id

**Platforms**:
| | iOS | Android | Python |
|---|-----|---------|--------|
| X25519 | CryptoKit `Curve25519.KeyAgreement` | API 31+ / Tink | pynacl |
| ChaChaPoly | CryptoKit `ChaChaPoly` | API 28+ / Tink | pynacl |
| HKDF | CryptoKit `HKDF` | API 26+ / Tink | `cryptography` |

**Python file**: `mobile/crypto.py`
**Swift file**: `iosApp/iosApp/E2ECrypto.swift`

### 3. Hermes Agent — Mobile Module

**New files**:
```
~/.hermes/hermes-agent/mobile/
├── __init__.py
├── relay_client.py    # WSS connection to Relay, heartbeat, reconnect
├── crypto.py           # X25519 + ChaChaPoly encrypt/decrypt
├── pairing.py          # Pairing code generation, key exchange
└── bridge.py            # Bridge encrypted Relay messages → dispatch()
```

**Persistent files**:
```
~/.hermes/mobile/
├── keypair             # Agent X25519 private key + public key
├── paired_pubkey       # Paired App's public key
├── enc_key             # Derived encryption key
└── sequence            # Message sequence counter
```

**New CLI commands**:
```bash
hermes mobile pair       # Generate 6-digit pairing code, connect to Relay, wait for App
hermes mobile status      # Show pairing and connection status
hermes mobile unpair      # Remove pairing (delete keys)
hermes mobile start       # Start Relay connection (background)
hermes mobile stop        # Stop Relay connection
```

**Config**:
```yaml
# ~/.hermes/config.yaml
mobile:
  relay_url: "wss://erc8004list.xyz/relay"
  paired: true
```

**Auto-start**: Relay connection starts automatically with Gateway if `mobile.paired: true`

**Message flow**:
```
App → Relay → Agent:
  1. Agent receives data message from Relay
  2. Base64 decode → extract nonce → ChaChaPoly decrypt → JSON-RPC string
  3. Parse JSON-RPC → call dispatch(method, params)
  4. Get result → ChaChaPoly encrypt → base64 → send via Relay

Agent → App (events):
  1. Agent generates event (message.delta, approval.request, etc.)
  2. ChaChaPoly encrypt → base64 → send via Relay
  3. App decrypts → renders
```

### 4. Nexus App — Relay Client

**New files**:
```
iosApp/iosApp/
├── RelayClient.swift       # WSS connection to Relay, heartbeat, reconnect
├── E2ECrypto.swift         # X25519 + ChaChaPoly encrypt/decrypt
└── PairingView.swift       # 6-digit pairing code input UI
```

**Remove**:
- `HermesWSClient.swift` — replaced by `RelayClient.swift`
- `HermesWSDelegate` — no self-signed cert handling needed
- Gateway URL input field
- API Key input field
- DEBUG auto-fill URL/token
- `#if DEBUG` auto-connect logic

**Keep**:
- All Dashboard UI (Inbox/Agents/Sessions/Cron/Approvals)
- Chat rendering (Telegram style)
- `MobileGatewayClient.swift` data models
- `KeychainHelper.swift` (extended for key pair storage)
- `NexusStyle`

**App flow**:
```
First launch (unpaired):
  → PairingView: enter 6-digit code
  → Generate X25519 key pair → save to Keychain
  → WSS connect to Relay → join channel
  → Exchange public keys with Agent via Relay
  → ECDH → derive enc_key → save to Keychain
  → Receive encrypted "paired" confirmation
  → Enter Dashboard

Subsequent launches (paired):
  → Read enc_key from Keychain
  → WSS connect to Relay → join channel (using stored channel_id)
  → Start encrypted JSON-RPC communication
  → Enter Dashboard directly

Disconnected:
  → Auto-reconnect with exponential backoff (1s, 2s, 4s, 8s, max 30s)
  → Reuse stored keys, no re-pairing needed
```

### 5. Caddy Configuration

```caddy
erc8004list.xyz {
    handle /relay {
        reverse_proxy 127.0.0.1:9120
    }
    handle /api/* {
        reverse_proxy 127.0.0.1:9119
    }
}
```

## Pairing Flow (Detailed)

```
Step 1: Agent side
  $ hermes mobile pair
  → Generate X25519 keypair: priv_A, pub_A
  → Save to ~/.hermes/mobile/keypair
  → Generate 6-digit code: "482913"
  → channel_id = SHA256("482913")[:8].hex()
  → WSS connect to wss://erc8004list.xyz/relay
  → Send: {"type":"join","channel":"<channel_id>","role":"agent"}
  → Display: "Pairing code: 482913 — enter in Nexus app"

Step 2: App side
  → User enters "482913" in PairingView
  → Generate X25519 keypair: priv_B, pub_B
  → Save to Keychain
  → channel_id = SHA256("482913")[:8].hex()
  → WSS connect to wss://erc8004list.xyz/relay
  → Send: {"type":"join","channel":"<channel_id>","role":"app"}

Step 3: Relay
  → Both endpoints in channel → send {"type":"paired"} to both

Step 4: Key exchange
  → App sends: {"type":"data","channel":"<id>","payload":"base64(pub_B)"}
  → Agent receives pub_B, computes: shared = ECDH(priv_A, pub_B)
  → Agent derives: enc_key = HKDF(shared, salt="nexus-e2e", info="chachapoly-key")
  → Agent saves: paired_pubkey=pub_B, enc_key
  → Agent sends: {"type":"data","channel":"<id>","payload":"base64(pub_A)"}
  → App receives pub_A, computes: shared = ECDH(priv_B, pub_A)
  → App derives: enc_key = HKDF(shared, salt="nexus-e2e", info="chachapoly-key")
  → App saves: paired_pubkey=pub_A, enc_key, channel_id

Step 5: Verification
  → Agent sends encrypted: {"jsonrpc":"2.0","method":"event","params":{"type":"paired"}}
  → App decrypts, verifies, shows "Paired successfully"
  → Pairing code invalidated (not reusable)
  → Both sides persist keys for reconnect
```

## Message Encryption

```
Encrypt:
  1. plaintext = JSON-RPC JSON string (UTF-8)
  2. seq = next sequence number (incremented per direction)
  3. nonce = seq.to_bytes(4, 'big') + channel_id_bytes(8)
  4. ciphertext = ChaChaPoly.seal(plaintext, key=enc_key, nonce=nonce)
  5. wire_payload = base64(nonce + ciphertext)
  6. Send: {"type":"data","channel":"<id>","payload":"<wire_payload>"}

Decrypt:
  1. Receive data message, base64 decode payload
  2. Split: nonce = payload[:12], ciphertext = payload[12:]
  3. plaintext = ChaChaPoly.open(ciphertext, key=enc_key, nonce=nonce)
  4. Verify seq > last_received_seq (anti-replay)
  5. Parse JSON-RPC
  6. Route to handler
```

## Security Properties

| Property | Mechanism |
|----------|----------|
| Relay cannot read content | E2E encryption, Relay only sees channel_id + ciphertext |
| Replay protection | Sequence numbers, monotonically increasing, reject old |
| Tamper detection | ChaChaPoly AEAD authentication tag |
| Pairing code security | 6 digits = ~20 bits, single-use, expires on success |
| Key persistence | Keys stored in platform secure storage (Keychain/Keystore/file 0600) |
| No inbound ports | Agent connects outbound to Relay |
| Unpair | `hermes mobile unpair` deletes all keys, App must re-pair |

## Implementation Tasks

### Phase 1: Relay Server (Day 1)
- [ ] Write `relay_server.py` (~200 lines)
- [ ] Deploy to jp-lighthouse
- [ ] Configure Caddy `/relay` route
- [ ] Verify WSS connectivity from local machine

### Phase 2: Crypto Module (Day 2)
- [ ] Write Python `mobile/crypto.py` (pynacl: X25519 + ChaChaPoly + HKDF)
- [ ] Write Swift `E2ECrypto.swift` (CryptoKit: Curve25519 + ChaChaPoly + HKDF)
- [ ] Unit test: encrypt on Python, decrypt on Swift (and vice versa)

### Phase 3: Agent Side (Day 3-4)
- [ ] Write `mobile/relay_client.py` (WSS connect, heartbeat, reconnect)
- [ ] Write `mobile/pairing.py` (pairing code, key exchange)
- [ ] Write `mobile/bridge.py` (decrypt → dispatch → encrypt response)
- [ ] Add CLI commands: `hermes mobile pair/status/unpair/start/stop`
- [ ] Add config section: `mobile.relay_url`, `mobile.paired`
- [ ] Auto-start with Gateway if paired
- [ ] Test: `hermes mobile pair` → verify Agent connects to Relay

### Phase 4: Nexus App (Day 5-6)
- [ ] Write `RelayClient.swift` (WSS connect, heartbeat, reconnect)
- [ ] Write `PairingView.swift` (6-digit code input)
- [ ] Integrate `E2ECrypto.swift` for encrypt/decrypt
- [ ] Remove `HermesWSClient.swift`, `HermesWSDelegate`, URL/token inputs
- [ ] Update `ContentView.swift` to use RelayClient instead of HermesWSClient
- [ ] Keep all Dashboard UI, chat rendering, data models
- [ ] Build for simulator

### Phase 5: Integration Test (Day 7)
- [ ] Run `hermes mobile pair` on server
- [ ] Enter pairing code in simulator Nexus app
- [ ] Verify: paired → Dashboard loads → Sessions/Agents/Cron visible
- [ ] Verify: chat send/receive works with E2E encryption
- [ ] Verify: disconnect/reconnect without re-pairing
- [ ] Verify: Relay logs show only encrypted bytes

### Phase 6: Real Device (Day 7.5)
- [ ] Build for iPhone 14 Pro
- [ ] Install and pair
- [ ] Verify full flow on real device

### Phase 7: Documentation (Day 8)
- [ ] Update README with new architecture
- [ ] Document relay deployment
- [ ] Document pairing instructions
- [ ] Document troubleshooting

## File Inventory

### New files
```
# Relay Server
relay_server.py                          # Standalone relay, ~200 lines

# Hermes Agent
mobile/__init__.py                       # Module init
mobile/relay_client.py                    # WSS client to Relay
mobile/crypto.py                          # X25519 + ChaChaPoly + HKDF
mobile/pairing.py                         # Pairing code + key exchange
mobile/bridge.py                          # JSON-RPC bridge

# Nexus iOS
iosApp/iosApp/RelayClient.swift           # WSS client to Relay
iosApp/iosApp/E2ECrypto.swift             # CryptoKit E2E encryption
iosApp/iosApp/PairingView.swift           # Pairing code UI
```

### Modified files
```
# Hermes Agent
hermes_cli/main.py                        # Add `hermes mobile` subcommand
hermes_cli/config.py                      # Add mobile config section
gateway/run.py                             # Auto-start relay client

# Nexus iOS
iosApp/iosApp/ContentView.swift            # Use RelayClient, remove URL/token inputs
iosApp/iosApp/KeychainHelper.swift         # Add key pair storage
```

### Removed files
```
iosApp/iosApp/HermesWSClient.swift         # Replaced by RelayClient
```

## Verification Criteria

1. **Relay**: `wss://erc8004list.xyz/relay` reachable, forwards bytes without parsing
2. **Crypto**: Python-encrypted message decrypts correctly in Swift (and vice versa)
3. **Pairing**: 6-digit code → both sides derive same enc_key → encrypted "paired" confirmation received
4. **Dashboard**: After pairing, App shows Sessions/Agents/Cron/Approvals (same as current Dashboard)
5. **Chat**: User sends message → Agent responds → App renders reply (all encrypted)
6. **Reconnect**: Kill App → reopen → auto-reconnect without re-pairing → communication resumes
7. **Relay logs**: Show only channel_id + base64 payload, no plaintext
8. **Real device**: iPhone 14 Pro pairs and communicates successfully