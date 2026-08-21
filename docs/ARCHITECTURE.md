# Nexus iOS — Architecture

Date: 2026-08-20 (post agent-centric refactor; `ContentView` removed)
Scope: the iOS app (`apps/iosApp/iosApp/`). The relay/agent/E2E Python stack lives
in `relay/` and is documented in `docs/RELAY-DEPLOYMENT.md`.

## 1. Design principles

- **Agent-first UI.** The first screen is an *agent home*, not a session list or
  dashboard. Sessions exist only as the backing thread of an agent chat.
- **Server = pairing unit, Agent = product unit.** A user pairs *servers*
  (Hermes Agents reachable via a relay); inside the app they see *agents* they
  explicitly add, each bound to one server + one session.
- **Thin transport, thick privacy.** All relay traffic is end-to-end encrypted
  (X25519 ECDH + ChaCha20-Poly1305, see §4); the relay only forwards opaque
  ciphertext. The phone is a low-trust device: the agent-side relay only
  allows an allowlisted set of methods (see `relay/relay_agent.py`).
- **Stable identity.** Agent `id` is a stable local UUID that never changes
  during its lifetime; the server session id it binds to is stored separately
  (`boundSessionID`). This keeps SwiftUI navigation and persisted chat caches
  keyed on an id that does not mutate.

## 2. Layered architecture

```
┌─────────────────────────────────────────────────────────┐
│  UI layer (SwiftUI)                                     │
│                                                         │
│  PairingView  AgentHomeView → AgentChatView             │
│       └─ QRScannerView   └─ AgentComposeView            │
│                          └─ AgentDetailView             │
│                          └─ Settings sheet              │
├─────────────────────────────────────────────────────────┤
│  App shell                                               │
│  NexusApp (root switch: servers.isEmpty ? Pairing       │
│  : AgentHomeView; ShowPairingView sheet)                │
├─────────────────────────────────────────────────────────┤
│  State & persistence                                     │
│  AgentRegistry (@MainActor ObservableObject)            │
│    ├─ agents: [NexusAgent]        → AgentStore(UserDefaults) │
│    └─ chats: [String:[TimelineItem]]                    │
│  ServerStore (UserDefaults)        ← ServerProfile      │
│  KeychainHelper (secrets: E2E keys, counters)           │
├─────────────────────────────────────────────────────────┤
│  Transport layer                                         │
│  RelayClient (one ServerConnection per paired server,   │
│  active-server RPC routing, status fan-out)             │
│  ServerConnection (URLSessionWebSocket: connect/rekey,  │
│  pairing state machine, pending-RPC table, seq counters)│
├─────────────────────────────────────────────────────────┤
│  Crypto layer (E2ECrypto, stateless)                    │
│  raw X25519 + HKDF + ChaCha20-Poly1305, PSK-blend,      │
│  directional subkeys, 4B-seq+8B-channel nonce, rekey    │
├─────────────────────────────────────────────────────────┤
│  Models (stateless)                                     │
│  NexusAgent / AgentStatus / ServerProfile /             │
│  SessionSummary / TimelineItem / SessionIDExtractor     │
│  (MobileGatewayClient.swift holds SessionSummary+TimelineItem)│
└─────────────────────────────────────────────────────────┘
```

## 3. File map

| File | Lines | Responsibility |
|------|------:|----------------|
| `NexusApp.swift` | 31 | Root switch (pair vs home), `ShowPairingView` sheet |
| `AgentHomeView.swift` | 329 | Agent home: grouped list, empty states, approval badge, offline/lostKeys dim, re-pair, context menu |
| `AgentChatView.swift` | 204 | Single-thread chat: history, send (create→bind→submit), interrupt, preview |
| `AgentViews.swift` | 218 | `AgentComposeView` (new chat / import), `AgentDetailView` (edit/delete) |
| `PairingView.swift` | 367 | Pairing entry: server config, pairing code, QR scan |
| `QRScannerView.swift` | 177 | AVFoundation QR scanning with permission handling |
| `AgentStore.swift` | 132 | `AgentStore` (UserDefaults) + `AgentRegistry` (in-memory, publish) |
| `Agent.swift` | 62 | `NexusAgent` model + `AgentStatus` |
| `ServerProfile.swift` | 65 | `ServerProfile` + `ServerStore` (UserDefaults, legacy migration) |
| `RelayClient.swift` | 166 | Multi-server connection management + RPC routing |
| `ServerConnection.swift` | 463 | Per-server WebSocket: E2E state, pairing, rekey, RPC |
| `E2ECrypto.swift` | 138 | All crypto primitives (stateless) |
| `SessionIDExtractor.swift` | 33 | Extract live session id from gateway results (shared) |
| `MobileGatewayClient.swift` | 24 | `SessionSummary`, `TimelineItem` (Codable for chat cache) |
| `NexusStyle.swift` | 107 | Colors, `ToastMessage`/`ToastView`, `cardStyle` |
| `KeychainHelper.swift` | 55 | Keychain read/write/delete wrapper |

Total: ~2,570 lines across 16 files (down from a single 3,000-line `ContentView`).

## 4. Security architecture (wire)

- **Key exchange (first pair):** app generates fresh Curve25519 keypair; agent
  sends its public key over the shared channel; app derives
  `shared = X25519(myPriv, agentPub)` then **PSK-blends** it with the pairing
  code via `HKDF(raw, salt=code, info="chachapoly-psk-blend", 32)` — a relay
  MITM that knows only the channel cannot derive the same secret.
- **Session keys:** `HKDF(shared, salt="nexus-e2e", info="chachapoly-key-{agent_to_app|app_to_agent}", 32)`
  separates direction so counter+key never collide across the two flows.
- **Nonce:** 4-byte big-endian sequence + 8-byte channel id (12 total).
- **Replay protection:** each side tracks its receive sequence and rejects
  mismatches; counters reset on reconnect/rekey.
- **Rekey:** on agent reconnect, both sides send fresh plaintext public keys and
  re-derive session keys + reset counters (keystream-reuse protection).
- **Server identity:** persisted under server-specific Keychain key prefix
  `srv_<serverID>_*`; keys `ThisDeviceOnly`; a server whose keys are lost
  refuses to enter *unblinded* pairing (PSK=nil) and fails loudly, forcing a
  clean re-pair.
- **Low-trust phone:** the agent's relay allowlist constrains allowed methods;
  the app never adds a method outside it (see `relay/relay_agent.py`).

## 5. Data flows

### 5.1 Pair a server (add a server)
1. `PairingView` collects relay URL + 8-12 char pairing code (typed or QR).
2. `RelayClient.addServer` → `E2ECrypto.channelIdFromPairingCode(code)` →
   `ServerConnection.startPairing(code)`.
3. Connection opens → `join` with channel → agent replies `paired` →
   public-key exchange → PSK-blended ECDH → keys persisted to Keychain.
4. Success posts `RelayPaired`; failure removes the server + posts
   `RelayPairingFailed` (Home marks bound agents `lostKeys` with actionable
   re-pair).

### 5.2 Add an agent
- **New chat:** `AgentComposeView` (server picker) → `session.create` on first
  send → bind live sid → `prompt.submit`. Defers server provisioning to v2.
- **Import session:** `AgentComposeView` import mode lists `session.list` →
  on save `session.resume(persistedKey)` resolves the compression-chain live
  sid → bind that (a static persisted-key binding would 4001 in
  `prompt.submit`/`history`).

### 5.3 Chat
- `AgentChatView.onAppear` → `ensureActiveServer` (set active + poll up to 3s)
  → `session.history(live sid)` → decode timeline → cache.
- Send → `session.create` if local-only, else reuse bound live sid →
  `prompt.submit` → `setPreview` → reload history.
- Interrupt → `session.interrupt` then reload.

### 5.4 Offline / re-pair
- `syncStatus` reflects each server's connection state onto its agents
  (`updateStatus` / `registry.agents = agents` to re-publish).
- `RelayPairingFailed` → `setLostKeys` (distinct from transient offline).
- Re-pair entry points: Settings server row, agent context menu.

## 6. Verification & testing

- `iosAppTests/contract-tests.swift` — executable regression contract checks
  (6 tests) for the session-id extraction shapes; run with
  `swift iosAppTests/contract-tests.swift` (no Xcode build needed).
- Build: `xcodebuild -project apps/iosApp/iosApp.xcodeproj -scheme iosApp ... build`.
- A formal XCTest target is planned together with moving the Xcode project to
  XcodeGen (`project.yml`) so the app and unit-test targets are declared
  together (current hand-written `.pbxproj` makes a test-host target risky to
  append manually).

## 7. Known boundaries / next steps

- **No streaming payload path yet:** chat reloads history after submit rather
  than consuming `message.delta` events live.
- **No agent→agent communication UI:** the relay allows `prompt.submit` only;
  cross-agent messaging requires a server-side scoped-session model (v2).
- **Approvals:** surfaced as a badge + toast; no dedicated approvals pane.
- **XCTest target + XcodeGen**: consolidation as above.
