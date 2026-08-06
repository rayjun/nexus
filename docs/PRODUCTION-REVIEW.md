# Nexus Production Readiness Review

Review date: 2026-08-05
Scope: Relay architecture (relay_server.py, relay_agent.py, crypto.py, E2ECrypto.swift, RelayClient.swift, ContentView.swift)

## Verified working ✅

- E2E crypto cross-platform (Python ↔ Swift) verified
- Pairing flow (6-digit code → key exchange → encrypted channel)
- Reconnect flow (peer drop → relay closes peer → auto-reconnect)
- Real Dashboard bridge (43 sessions, 2 cron jobs via real Hermes WS)
- iOS app renders Dashboard over encrypted relay

## Issues found — MUST FIX before production

### CRITICAL

1. **relayURL hardcoded to localhost** (`RelayClient.swift:34`)
   `let relayURL = "ws://127.0.0.1:9120"` — this is the DEBUG simulator address.
   Production must use `wss://<domain>/relay` and should be configurable (not
   hardcoded), or the app only works against a local relay.

2. **ATS allows arbitrary loads** (`Info.plist`)
   `NSAllowsArbitraryLoads=true` permits plaintext HTTP everywhere.
   Must be tightened: allow only the relay domain over WSS, or use
   `NSAllowsLocalNetworking` for DEBUG only.

3. **ContentView still contains legacy connection UI** (`ContentView.swift:76,125-167,1858+`)
   `connectView` (GATEWAY/API KEY inputs), `connect()`, `HermesWSClient`
   creation at line 1885 — dead code from the direct-connection era. It can
   confuse users (app shows connection screen when relay not yet connected)
   and must be removed. `isConnected` gates on `RelayClient.shared.isConnected`
   so the legacy path is unreachable, but the dead code should be deleted.

### HIGH

4. **SwiftUI observation missing** (`ContentView.swift:65-67`, `NexusApp.swift`)
   `isConnected` reads `RelayClient.shared.isConnected` as a computed property,
   but ContentView never declares `@EnvironmentObject var relay: RelayClient`
   even though NexusApp injects it. `@Published` changes do NOT trigger SwiftUI
   re-render for a plain computed property. The `.onChange(of:)` at line 96
   partially compensates, but initial-load races remain (e.g. relay connects
   before view appears → onChange never fires → home data never loads).
   Fix: add `@EnvironmentObject var relay: RelayClient` and use `relay.isConnected`.

5. **No auth/rate limiting on Relay** (`relay_server.py`)
   Anyone can join any channel_id (8 hex chars = 32 bits) and occupy it.
   A malicious client could:
   - Join a victim's channel as "app" and intercept the pairing public keys
     (MITM the initial key exchange — both keys pass through the relay!)
   - Fill channels to exhaust memory (no per-IP or total connection limits)
   - Flood `data` messages (no payload size limit, no rate limit)
   The 32-bit channel_id from a 6-digit code (SHA256 prefix) is brute-forceable
   at relay scale. Requires: pairing code confirmed on both sides before keys
   are trusted, per-IP caps, payload size cap, connection limits.

6. **MITM window during pairing** (`relay_agent.py:104-116`)
   Public keys are exchanged in plaintext through the relay. If an attacker
   joins the channel first (channel_id is only 32 bits from a guessable 6-digit
   code), they can substitute their own public key and impersonate either side.
   The 6-digit code (10^6 ≈ 20 bits) + 8-hex channel (32 bits) is NOT enough
   entropy for untrusted relays. Mitigation: pairing code shown on BOTH devices
   (out-of-band confirmation), or use a longer code, or sign the key exchange
   with the pairing code as a pre-shared key.

### MEDIUM

7. **No nonce/sequence validation on receive** (`RelayClient.swift:226`, `relay_agent.py:169`)
   `recvSeq += 1` counts but never validates monotonicity. Replay of an old
   encrypted message would be decrypted and processed (though the AEAD tag
   prevents tampering, replay of a valid captured message is possible).
   Should reject messages with seq <= last seen.

8. **No payload size limit** (`relay_server.py:forward`)
   A client can send arbitrarily large base64 payloads, causing memory
   exhaustion. Add max payload size (e.g. 1MB) and reject oversized messages.

9. **Dashboard token in CLI argument** (`relay_agent.py:260`)
   `--dashboard "ws://127.0.0.1:9119/api/ws?token=..."` puts the token in
   process list / shell history / systemd unit. Should read from env var
   (e.g. `HERMES_DASHBOARD_SESSION_TOKEN`) instead.

10. **iOS Keychain stores pairing key but not access-control** (`KeychainHelper.swift`)
    Keys use `kSecAttrAccessibleAfterFirstUnlock` — fine, but the E2E private
    key should ideally use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` +
    `kSecUseAuthenticationContext` for sensitive key material.

### LOW

11. **`run()` reconnect waits for "paired" forever** (`relay_agent.py:196-201`)
    If the agent reconnects but the app is offline, it blocks on recv waiting
    for "paired" that never comes. Should enter message loop regardless and
    let the relay notify on app join.

12. **Channel cleanup deletes active channels after 24h** (`relay_server.py:149`)
    `age > 86400` for both_connected channels — a long-lived pairing is
    silently destroyed after 24h and both sides must re-pair. Reconsider.

13. **Unused imports / dead code** (`crypto.py:13-17`: hashlib, Optional;
    `relay_agent.py:27`: KeyPair as KP duplicate import; `MobileGatewayClient.swift`
    legacy models)

## Missing for production

- Automated tests (unit: crypto vectors; integration: relay forward/pair/reconnect)
- Relay monitoring (connection count, channel count, payload stats, logs to file)
- Key rotation / re-pair UX in the app (unpair button)
- App-side relay URL configuration UI (or build-time config)
- Multi-device support (one agent ↔ multiple apps) — currently single app per channel
- CI (build + test on push)
- Version pinning of Python deps (requirements.txt)

## Recommendation

**Not production-ready yet.** The core crypto and relay flow work, but the
hardcoded localhost relay URL, open ATS, legacy UI dead code, missing SwiftUI
observation, and the unauthenticated pairing MITM window are blockers. Fix
CRITICAL + HIGH items first (est. 1-2 days), then add tests + monitoring.
