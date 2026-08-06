# Relay Deployment & Configuration

## Architecture

```
┌──────────────┐     WSS (outbound)    ┌──────────┐     WSS (outbound)    ┌──────────────┐
│ Hermes Agent │ ←──────────────────→  │  Relay   │  ←──────────────────→  │  Nexus App   │
│ (user server)│   E2E encrypted      │ (public)  │   E2E encrypted       │ (iOS/Android) │
└──────────────┘                      └──────────┘                      └──────────────┘
```

- **Hermes Agent** (`relay_agent.py`): runs alongside Hermes Gateway, connects outbound to Relay, bridges E2E-encrypted JSON-RPC to the real Hermes Dashboard WebSocket.
- **Relay Server** (`relay_server.py`): public server with trusted TLS (Caddy + Let's Encrypt). Routes encrypted bytes between paired endpoints. Never sees plaintext.
- **Nexus App**: phone side, connects outbound to Relay.

Security properties:
- X25519 key agreement + ChaCha20-Poly1305 AEAD encryption
- Relay sees only `channel_id` + ciphertext (never message content)
- 6-digit pairing code, single-use
- Agent opens no inbound ports (outbound WSS only)

---

## Components

| File | Role |
|------|------|
| `relay/relay_server.py` | Public WebSocket relay (~200 lines) |
| `relay/relay_agent.py` | Agent-side client: pairing + E2E bridge to Dashboard |
| `relay/crypto.py` | X25519 + ChaChaPoly + HKDF (pynacl + cryptography) |

iOS side (in the Nexus app):
| File | Role |
|------|------|
| `iosApp/iosApp/RelayClient.swift` | WSS client: pairing + RPC over E2E channel |
| `iosApp/iosApp/E2ECrypto.swift` | CryptoKit implementation of the same crypto |
| `iosApp/iosApp/PairingView.swift` | 6-digit pairing code UI |

---

## 1. Deploy the Relay Server

### Prerequisites

- A public server with a domain pointing at it (A record). Throughout this
  document `<relay.example.com>` is a placeholder — substitute your own
  domain; no concrete domain is hardcoded anywhere in the repo.
- Caddy installed (or any TLS terminator)
- Python 3.11+ with `websockets`, `pynacl`, `cryptography`

### Quick install (deploy script)

The repo ships `relay/deploy-relay.sh`, which installs the relay files,
Python deps, a Caddy `/relay` route, and systemd services in one go:

```bash
# from the repo root
bash relay/deploy-relay.sh install <relay.example.com>
```

It creates:

- `~/nexus-relay/{relay_server.py,crypto.py,relay_agent.py}`
- systemd unit `nexus-relay.service` (the public relay on `127.0.0.1:9120`)
- systemd unit `nexus-relay-agent.service` (agent client; enable AFTER pairing)
- a Caddy site block proxying `https://<relay.example.com>/relay` → `127.0.0.1:9120`

### Manual install

```bash
mkdir -p ~/nexus-relay
cd ~/nexus-relay

# Copy relay_server.py and crypto.py from the repo
# (or git clone the repo and copy from relay/)

pip3 install websockets pynacl cryptography
```

### Configure Caddy

Caddyfile (port 443):

```caddy
your-domain.com {
    handle /relay {
        reverse_proxy 127.0.0.1:9120
    }
    # Security: do NOT proxy /api/* to the Dashboard here. The Nexus app
    # reaches Hermes through the encrypted relay only, and exposing the
    # tokenized Dashboard on the public internet is a leak vector.
}
```

Restart Caddy:

```bash
sudo systemctl restart caddy
```

### Run the Relay Server

Foreground (test):

```bash
python3 relay_server.py
```

As a systemd service:

```ini
# /etc/systemd/system/nexus-relay.service
[Unit]
Description=Nexus Relay Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /home/ubuntu/nexus-relay/relay_server.py
Restart=always
RestartSec=3
User=ubuntu

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nexus-relay
```

The relay listens on `127.0.0.1:9120` by default. Caddy terminates TLS and proxies `wss://your-domain.com/relay` → `ws://127.0.0.1:9120`.

---

## 2. Configure the Hermes Agent side

### Prerequisites

- Hermes Gateway/Dashboard running on the same machine (or reachable)
- Dashboard WebSocket URL + session token

### First-time pairing

```bash
python3 relay_agent.py \
  --relay wss://your-domain.com/relay \
  --dashboard "ws://127.0.0.1:9119/api/ws?token=YOUR_DASHBOARD_TOKEN" \
  --pair --code 123456
```

Output:

```
Pairing code: 123456
Enter this in Nexus app.
```

Enter the same code in the Nexus app's Pairing screen. The agent prints `pairing complete` and starts the communication loop.

### Normal run (after pairing)

```bash
python3 relay_agent.py \
  --relay wss://your-domain.com/relay \
  --dashboard "ws://127.0.0.1:9119/api/ws?token=YOUR_DASHBOARD_TOKEN"
```

The agent:
1. Loads persisted pairing state from `~/.hermes/mobile/`
2. Connects outbound to the Relay
3. Waits for the paired app to connect
4. Bridges every encrypted JSON-RPC call to the real Dashboard
5. Reconnects automatically if the Relay connection drops

### As a systemd service

```ini
# /etc/systemd/system/nexus-relay-agent.service
[Unit]
Description=Nexus Relay Agent
After=network.target nexus-relay.service

[Service]
ExecStart=/usr/bin/python3 /home/ubuntu/nexus-relay/relay_agent.py \
  --relay wss://your-domain.com/relay \
  --dashboard "ws://127.0.0.1:9119/api/ws?token=YOUR_DASHBOARD_TOKEN"
Restart=always
RestartSec=5
User=ubuntu

[Install]
WantedBy=multi-user.target
```

### Pairing state files

Persisted under `~/.hermes/mobile/`:

| File | Content |
|------|---------|
| `keypair` | Agent X25519 key pair (private + public, 0600) |
| `paired_pubkey` | Paired app's public key |
| `enc_key` | Derived ChaChaPoly encryption key |
| `channel_id` | Channel ID (SHA-256 of pairing code, 8 hex chars) |
| `send_seq` / `recv_seq` | Message sequence counters |

To unpair:

```bash
rm -rf ~/.hermes/mobile
```

Then re-pair with a new code.

---

## 3. Configure the Nexus App

### iOS

The relay URL is read from UserDefaults key `relay_url`. If unset, DEBUG
builds default to `ws://127.0.0.1:9120` (simulator) and Release builds to
`wss://relay.example.com/relay`. Point the app at your deployed relay:

```bash
# on the device/simulator (or set relay_url in your app's settings)
xcrun simctl spawn <UDID> defaults write com.rayjun.nexus relay_url -string "wss://your-domain.com/relay"
```

- First launch shows the Pairing screen (6-digit code)
- After pairing, the app auto-connects to the Relay and enters the Dashboard
- Pairing keys are stored in Keychain (`relay_enc_key`, `relay_channel_id`, `relay_priv_key`)

### DEBUG simulator override

In DEBUG builds, the app reads `relay_enc_key` and `relay_channel_id` from `UserDefaults` before falling back to Keychain. This lets you inject a pairing state without UI interaction:

```bash
xcrun simctl spawn <UDID> defaults write com.rayjun.nexus relay_enc_key -string "<base64-key>"
xcrun simctl spawn <UDID> defaults write com.rayjun.nexus relay_channel_id -string "<channel-id>"
```

---

## 4. Pairing Flow (detailed)

```
1. Agent:  relay_agent.py --pair --code 123456
   → generates X25519 keypair, saves to ~/.hermes/mobile/keypair
   → channel_id = SHA256("123456")[:8]
   → connects to Relay, joins channel as "agent"

2. App: user enters "123456"
   → generates X25519 keypair, saves to Keychain
   → connects to Relay, joins channel as "app"

3. Relay: both endpoints in channel → sends {"type":"paired"} to both

4. Key exchange (through Relay, plaintext public keys):
   app → agent: pub_app
   agent → app: pub_agent
   both: shared = ECDH(my_priv, peer_pub)
         enc_key = HKDF-SHA256(shared, salt="nexus-e2e", info="chachapoly-key")

5. Agent sends encrypted {"jsonrpc":"2.0","method":"event","params":{"type":"paired"}}
   App decrypts → "Paired successfully"
   Pairing code invalidated
```

After pairing, every message is encrypted:

```
wire = base64(nonce(12B) + ChaChaPoly.seal(json_rpc, key=enc_key, nonce))
nonce = sequence(4B big-endian) + channel_id_bytes(8B)
```

---

## 5. Relay Protocol

All messages are JSON text frames.

Client → Relay:

```json
{"type": "join", "channel": "4a8eec49", "role": "agent"}
{"type": "data", "channel": "4a8eec49", "payload": "base64(E2E encrypted bytes)"}
{"type": "ping"}
```

Relay → Client:

```json
{"type": "paired", "channel": "4a8eec49"}
{"type": "data", "channel": "4a8eec49", "payload": "base64(...)"}
{"type": "pong"}
{"type": "error", "message": "..."}
```

Relay behavior:
- Matches endpoints by channel ID
- Forwards `data` payloads verbatim without parsing
- Sends `paired` when both endpoints have joined
- When one endpoint disconnects, closes the peer's connection so it reconnects cleanly
- Relies on the `websockets` library keepalive (not a custom heartbeat)

---

## 6. JSON-RPC Methods (bridged to real Dashboard)

The agent forwards every method to the Hermes Dashboard WebSocket:

| Method | Purpose |
|--------|---------|
| `session.list` | List sessions |
| `session.resume` | Resume a session (returns active id + messages) |
| `session.history` | Session message history |
| `session.status` | Session status |
| `session.interrupt` | Interrupt running session |
| `prompt.submit` | Send a user message |
| `approval.respond` | Approve/deny pending command |
| `cron.manage` | List/manage cron jobs |
| `agents.list` | List agents |
| `config.get` | Read Hermes config |
| `model.options` | Available models |
| `tools.list` / `toolsets.list` | Available tools |

---

## 7. Upgrade

Upgrading the relay stack (relay server, crypto, agent client) is
non-disruptive for the agent (it reconnects automatically) and requires no
re-pairing — E2E keys are persisted on both ends.

### Option A — deploy script (recommended)

```bash
# from the repo root
bash relay/deploy-relay.sh upgrade <relay.example.com> /path/to/nexus
```

This copies the three relay files from the given checkout, reloads Caddy if
needed, and restarts `nexus-relay.service`. `nexus-relay-agent.service` is
NOT auto-restarted by the script — restart it after you've confirmed the new
agent files work:

```bash
sudo systemctl restart nexus-relay-agent.service
```

> The pairing state under `~/.hermes/mobile/` is untouched by upgrades, so
> the phone stays paired.

### Option B — manual

```bash
# 1. get latest files
git -C /path/to/nexus pull --ff-only        # or clone fresh
cp /path/to/nexus/relay/{relay_server.py,crypto.py,relay_agent.py} ~/nexus-relay/

# 2. restart the relay daemon
sudo systemctl restart nexus-relay.service

# 3. verify
sudo systemctl status nexus-relay.service --no-pager | head -5
curl -s https://<relay.example.com>/relay | head -c 200

# 4. restart the agent daemon (after verifying the relay)
sudo systemctl restart nexus-relay-agent.service
```

### What upgrades do NOT change

- The relay protocol (`join`/`data`/`paired`) — backwards compatible.
- The E2E crypto — key derivation, nonce layout and channel-id scheme are
  stable; re-pairing is NOT required across upgrades.
- The app side — iOS/Android clients connect with the same pairing state.

### Rollback

```bash
# restore the previous files (e.g. from git history), then:
sudo systemctl restart nexus-relay.service
sudo systemctl restart nexus-relay-agent.service
```

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| App stuck on "Waiting for agent..." | Agent not connected to Relay, or pairing code mismatch | Check agent logs; verify `--relay` URL; re-pair with a fresh code |
| `join failed` | Same role already connected on the channel | Restart both sides; use a new pairing code |
| `peer not connected` | Peer dropped; Relay closed your connection | Agent/app auto-reconnect; wait 3-5s |
| Decrypt failures in agent logs | Key mismatch (pairing state desynced) | `rm -rf ~/.hermes/mobile` on agent; re-pair |
| `dashboard unavailable` | Dashboard not running or bad token | Verify `ws://127.0.0.1:9119/api/ws?token=...` with a Python client first |
| 100% CPU on relay_agent | Old version with broken reconnect loop | Update to latest; the current loop sleeps 3s between reconnects |

### Verify the Dashboard endpoint first

Before blaming the relay, confirm the Dashboard WS works directly:

```python
import asyncio, json, websockets

async def t():
    async with websockets.connect("ws://127.0.0.1:9119/api/ws?token=YOUR_TOKEN") as ws:
        m = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
        print("ready:", m["params"]["type"])
        await ws.send(json.dumps({"jsonrpc":"2.0","id":1,"method":"session.list","params":{"limit":5}}))
        resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
        print("sessions:", len(resp["result"]["sessions"]))

asyncio.run(t())
```
