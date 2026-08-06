# Nexus Production Readiness Review

Review date: 2026-08-05
Scope: Relay architecture (relay_server.py, relay_agent.py, crypto.py, E2ECrypto.swift, RelayClient.swift, ContentView.swift)
Method: manual review + independent security subagent audit

## Verified working ✅

- E2E crypto cross-platform (Python ↔ Swift) verified
- Pairing flow (6-digit code → key exchange → encrypted channel)
- Reconnect flow (peer drop → relay closes peer → auto-reconnect)
- Real Dashboard bridge (43 sessions, 2 cron jobs via real Hermes WS)
- iOS app renders Dashboard over encrypted relay

## Issues found — MUST FIX before production

### 🔴 CRITICAL

#### C1. Bidirectional nonce reuse — ChaCha20 keystream reuse kills E2E encryption
- `crypto.py:80-83` (make_nonce), `E2ECrypto.swift:32-44` (encrypt)
- Both sides derive the SAME enc_key from the same ECDH shared secret
  (`crypto.py:66-73` has no direction separation), and BOTH send counters
  start at 0 independently. The agent's first encrypted message (seq=0) and
  the app's first RPC (seq=0) use the same key + same nonce. ChaCha20 is a
  stream cipher: C1⊕C2 = P1⊕P2. Anyone observing both directions can recover
  the keystream and decrypt all traffic.
- Fix: derive per-direction subkeys (HKDF info + "agent→app" / "app→agent"),
  AND/OR add a direction byte to the nonce. Do both.

#### C2. iOS counters reset to 0 on restart — cross-session nonce reuse
- `RelayClient.swift:29-30` (sendSeq/recvSeq memory-only), `RelayClient.swift:170-172`
- encKey persists in Keychain forever, but sendSeq/recvSeq do NOT persist.
  After app restart, iOS encrypts with seq=0 while the agent already used
  seq=0 in a previous session → same key + same nonce again.
- Fix: persist sendSeq/recvSeq in Keychain, or roll session keys per
  connection (re-ECDH → new session key, old key discarded).

#### C3. forward() has no membership check — unjoined connections inject data
- `relay_server.py:101-110`
- forward() checks `ws is ch.agent` for direction but NEVER verifies the
  sender actually joined that channel. Any bare connection that guesses an
  8-hex channel_id can inject data frames into it (garbage ciphertext → CPU
  DoS via repeated decrypt, or replayed ciphertext → arbitrary commands
  combined with missing replay protection).
- Fix: maintain a `ws → channel_id` membership map; verify before forward.

#### C4. relayURL hardcoded to localhost
- `RelayClient.swift:34` — `let relayURL = "ws://127.0.0.1:9120"`. Production
  must use `wss://<domain>/relay`, configurable (not hardcoded), plus TLS
  cert pinning. Plain `ws://` in production = MITM on the whole link.

#### C5. ATS allows arbitrary loads
- `Info.plist` — `NSAllowsArbitraryLoads=true` permits plaintext HTTP
  everywhere. Tighten to WSS-only for the relay domain (or
  NSAllowsLocalNetworking for DEBUG only).

#### C6. ContentView legacy connection UI dead code
- `ContentView.swift:76,125-167,1858+` — connectView (GATEWAY/API KEY
  inputs), connect(), HermesWSClient creation at line 1885. Unreachable via
  isConnected gate but must be deleted before release.

### 🟠 HIGH

#### H1. Pairing MITM — "relay never sees plaintext" fails under active attack
- `relay_server.py:64-88`, `relay_agent.py:268`, `RelayClient.swift:149-177`
- 6-digit code ≈ 20 bits; channel_id = SHA256(code)[:8] is precomputable by
  the relay (100万 code hash table in ms). Public keys exchanged in
  plaintext via relay with NO identity verification (no SAS, no fingerprint,
  no re-confirmation). A malicious relay joins as "app" first and substitutes
  its public key → full MITM.
- Fix: raise code entropy (8-10 digits) + attempt rate limit; add SAS
  (4-digit fingerprint comparison on both devices); or QR-code out-of-band
  key exchange.

#### H2. Dashboard token exposed + public Dashboard proxy
- `relay_agent.py:260`, `RELAY-DEPLOYMENT.md:167-169,71-73`
- Token in CLI args (visible in ps/history/systemd). Docs recommend proxying
  `/api/* → 127.0.0.1:9119` publicly — exposes tokenized Dashboard to the
  internet and puts token in Caddy logs.
- Fix: token via env var / systemd LoadCredential; REMOVE the public `/api/*`
  proxy (phone goes through Relay); redact Caddy logs.

#### H3. Phone has full Hermes control surface — no method allowlist
- `relay_agent.py:212-254`, `RELAY-DEPLOYMENT.md:289-307`
- After pairing, phone can call ANY Dashboard method. `config.get` returns
  Hermes config with LLM API keys; `approval.respond` can approve anything.
  A lost/jailbroken phone = full agent control.
- Fix: server-side method allowlist (session.* read + prompt.submit only);
  strip secrets from config.get; second confirmation for sensitive ops.

#### H4. No replay protection
- `crypto.py:94-98`, `relay_agent.py:164-170`, `E2ECrypto.swift:47-61`, `RelayClient.swift:226`
- Both decrypt paths never validate nonce sequence against expected recv_seq.
  Replayed ciphertext (e.g. duplicate prompt.submit → duplicate execution)
  decrypts successfully.
- Fix: reject if nonce.seq != expected recv_seq; disconnect on mismatch.

#### H5. dashboard_call concurrent response mismatch
- `relay_agent.py:245-250`
- Concurrent RPCs each spin `while True: recv()` on the SAME dash_ws — one
  coroutine can consume another's response. Random timeouts / wrong results.
- Fix: single reader coroutine dispatching by id to pending futures.

#### H6. iOS sendSeq unsynchronized increment
- `RelayClient.swift:265-269` — `sendSeq += 1` has no lock (pending dict has
  NSLock, counter doesn't). Concurrent call() → same nonce for two messages.
- Fix: lock or serialize sendSeq allocation.

#### H7. SwiftUI observation missing
- `ContentView.swift:65-67`, `NexusApp.swift` — `isConnected` reads
  `RelayClient.shared.isConnected` as a computed property but ContentView
  never declares `@EnvironmentObject`. @Published changes don't trigger
  re-render; initial-load races remain.
- Fix: add `@EnvironmentObject var relay: RelayClient`; use relay.isConnected.

### 🟡 MEDIUM

#### M1. No rate limiting — public DoS surface
- `relay_server.py:64-88,101-116,139-153`
- No connection cap, per-IP limit, join attempt limit, or payload size cap
  (relies on websockets ~1MiB default). Attackers can occupy channels for
  24h, brute-force pairing codes, or flood 1MB ciphertext at paired channels.
- Fix: asyncio.Semaphore total cap; per-IP token bucket; serve(max_size=64KB);
  channels cap + shorter dual-connection hold time.

#### M2. Pairing code uses non-crypto `hash()`
- `relay_agent.py:268` — `str(hash(os.urandom(4)) % 1000000)`. hash() is
  process-seeded, non-cryptographic; urandom only 4 bytes.
- Fix: `secrets.randbelow(1_000_000)`.

#### M3. Keychain entries migrate to iCloud backup
- `KeychainHelper.swift:20` — `kSecAttrAccessibleAfterFirstUnlock` backs up
  to iCloud; no explicit `kSecAttrSynchronizable: false`.
- Fix: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + synchronizable false.

#### M4. Single connection can join multiple channels; stale refs on drop
- `relay_server.py:155-198` — joined_channel tracks only the last one; a ws
  joining A then B leaves a dead ref in A on disconnect.
- Fix: track per-connection channel set; remove all on disconnect.

#### M5. No key rotation / pairing revocation
- `relay_agent.py:119-124`, `RelayClient.swift:170-172`
- enc_key and pairing are permanent; no rekey, no server-side revocation, no
  pairing expiry. Lost phone (app not uninstalled) = permanent control.
- Fix: session key rolling + server-side revocation + forced re-pair.

#### M6. Pairing state file robustness
- `relay_agent.py:53-63`, `crypto.py:135-142` — is_paired checks file
  existence only; seq writes non-atomic, no fsync; torn reads crash startup.
- Fix: atomic writes (tmp+rename+fsync), magic+checksum header, single-instance lock.

### 🔵 LOW

| # | Location | Issue | Fix |
|---|----------|-------|-----|
| L1 | `relay_server.py:168-189` | `msg.get` on JSON array/number raises AttributeError (self-DoS log spam) | isinstance(msg, dict) first |
| L2 | `RelayClient.swift:52-63` | DEBUG branch stores enc_key in UserDefaults (backup + forensics) | simulator-only + DEBUG gating |
| L3 | `RelayClient.swift:117-135` | pair()/connect() no code format validation; silent mismatch after re-pair | validate 6-digit; explicit error + re-pair guide |
| L4 | `relay_agent.py:111` | b64decode no try/except — malicious payload crashes process | wrap in try/except |
| L5 | `relay_server.py:189` | f-string echoes unknown type; no structured audit log | structured logging |
| L6 | `RelayClient.swift:82-86,105-107` | new URLSession per reconnect, never invalidated; timer + manual connect double-connection | reuse session; serialize reconnect |

## Missing for production

- Automated tests (unit: crypto vectors incl. nonce/direction; integration: relay forward/pair/reconnect/replay)
- Relay monitoring (connection count, channel count, payload stats, log to file)
- Key rotation / re-pair UX in the app (unpair button)
- App-side relay URL configuration (or build-time config)
- Multi-device support (one agent ↔ multiple apps)
- CI (build + test on push)
- Version pinning of Python deps (requirements.txt)

## Recommendation

**❌ Not production-ready.** The core crypto and relay flow work, but there
are 3 CRITICAL crypto/design flaws — bidirectional + cross-session nonce
reuse (C1+C2, breaks ChaCha20 entirely), missing forward membership check
(C3), unauthenticated pairing MITM (H1) — plus HIGH items (token exposure,
full control surface, no replay protection, concurrency mismatch, plaintext
ws URL).

**Minimum path to a degraded-threat-model release (honest relay, no active
attacker): fix C1+C2+C3+H4 (~1-2 days).** Full public release requires
H1/H2/H3 closed as well.

Priority order: C1/C2 key derivation refactor → C3 membership check → H4
replay validation → H7 wss config → H2 token governance → H3 method
allowlist → M1 rate limiting → H1 SAS pairing → H5/H6 concurrency fixes.
