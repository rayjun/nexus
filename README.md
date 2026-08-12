# Nexus

A native iOS app for managing AI agents powered by [Hermes Agent](https://github.com/NousResearch/hermes-agent). Connect to your Hermes gateway over an E2E-encrypted relay channel, chat with agents, browse sessions, and monitor tasks — all from your phone. Zero inbound ports on your server, zero certificate management on your device.

## Features

- **E2E-Encrypted Relay** — X25519 key agreement + ChaCha20-Poly1305 AEAD over a lightweight public relay. The relay only sees ciphertext and a channel ID; it never sees message content.
- **QR or Code Pairing** — Scan the agent's terminal QR with the phone camera, or type an 8-character code; E2E keys persist for automatic reconnect.
- **Session Management** — Browse and resume Hermes sessions with a full timeline view.
- **Agent Chat** — Send prompts to Hermes agents, approve/deny tool approvals, interrupt running sessions.
- **Cron & Automation** — View and manage Hermes cron jobs from your phone.
- **Markdown Rendering** — Headings, bold, italic, code blocks with syntax highlighting, lists, blockquotes, links.
- **Dark Mode** — Full dark mode support following system appearance.
- **Secure Storage** — E2E keys and pairing state stored in iOS Keychain.

## Architecture

```
┌──────────────┐    WSS (outbound)    ┌──────────┐    WSS (outbound)    ┌──────────────┐
│ Hermes Agent │ ←──────────────────→ │  Relay   │ ←──────────────────→ │  Nexus App   │
│ (user server)│     E2E encrypted    │ (public)  │    E2E encrypted    │    (iOS)     │
└──────────────┘                      └──────────┘                      └──────────────┘
```

The three components are independently deployable — the Agent does **not** have to run on the relay's host:

- **Relay Server** (`relay/relay_server.py`): a lightweight public WebSocket relay behind any TLS terminator (Caddy + Let's Encrypt). It routes encrypted bytes between paired endpoints and never parses message content.
- **Agent Client** (`relay/relay_agent.py` + `nexus-agent` CLI): runs on any machine that can reach your Hermes Dashboard. It connects **outbound** to the relay — your server opens no inbound ports. Pairing keys persist in `~/.hermes/mobile/`.
- **iOS App** (SwiftUI): `RelayClient.swift` + `E2ECrypto.swift` (CryptoKit) implement pairing, encryption, and JSON-RPC over the relay.

Security properties:

- **Confidentiality** — the relay operator cannot read traffic (direction-separated ChaChaPoly keys, fresh keys per connection, PSK-blinded key agreement).
- **Authenticity** — AEAD tags prevent tampering; replay of captured messages is rejected via monotonic sequence validation.
- **MITM resistance** — the pairing code is mixed into the key agreement (PSK-blended ECDH), so an on-path attacker who swaps public keys still cannot derive the session keys.
- **Least privilege** — the agent enforces a method allowlist; the relay rejects data from unjoined sockets and rate-limits join/flood abuse.

## Requirements

- iOS 16.0+
- Xcode 15+ / Swift 5.9+
- Hermes Agent v0.20.0+ with the Dashboard server running on loopback
- Python 3.10+ on the agent machine
- A public relay server (one-time setup, see below)

## Getting Started

Full deployment instructions: **[docs/RELAY-DEPLOYMENT.md](docs/RELAY-DEPLOYMENT.md)**

### 60-second setup

**1. Deploy the relay stack** (once, on a public server with a domain):

```bash
bash relay/deploy-relay.sh install <your-relay-domain>
```

**2. Install the agent CLI** on any machine that runs your Hermes Dashboard:

```bash
curl -fsSL https://raw.githubusercontent.com/rayjun/nexus/main/relay/install-agent.sh | bash
export PATH="$HOME/.local/bin:$PATH"
```

**3. Configure + pair**:

```bash
nexus-agent setup --relay wss://<your-relay-domain>/relay --code K7M2P9QX
nexus-agent pair        # shows a QR + code, waits for the app
```

**4. In the Nexus app**: tap **Add Server → Scan agent QR** and point the
camera at the terminal QR — the relay URL, code and server name are filled in
automatically. (Or type them manually.) → **Add Server** → Dashboard.

**5. Run supervised**:

```bash
nexus-agent start       # daemon + auto-reconnect
nexus-agent status      # verify
```

After pairing, the app reconnects automatically with the stored E2E keys — no
URL, token, or certificate configuration on the device.

### nexus-agent CLI reference

| Command | Purpose |
|---------|---------|
| `nexus-agent setup [--relay …] [--code …]` | Configure relay URL, pairing code, dashboard WS (interactive or flags) |
| `nexus-agent pair [--qr '<payload>']` | Show QR + code and wait for the app; `--qr` consumes a phone-generated payload |
| `nexus-agent start` | Run the agent as a background daemon (auto-reconnect) |
| `nexus-agent status` | Show running state |
| `nexus-agent stop` | Stop the daemon |
| `nexus-agent update` | Pull latest code and restart |

Dashboard credentials are read from the `HERMES_DASHBOARD_WS` environment
variable (or the `--dashboard` flag) so tokens never appear in shell history.

## Repository Layout

```
relay/
├── relay_server.py    # public WebSocket relay (routes encrypted bytes)
├── relay_agent.py     # agent-side client (pairing + Dashboard bridge, --daemon)
├── nexus_agent_cli.py # nexus-agent CLI (setup/pair/start/status/stop/update)
├── crypto.py          # X25519 + ChaCha20-Poly1305 + HKDF (stdlib)
├── deploy-relay.sh    # install/upgrade script for the server
├── install-agent.sh   # one-command agent CLI installer
├── requirements.txt   # pinned agent dependencies
└── README.md

apps/iosApp/iosApp/
├── RelayClient.swift  # WebSocket client: pairing + E2E JSON-RPC
├── E2ECrypto.swift    # CryptoKit implementation of the same crypto
├── PairingView.swift  # pairing UI + QR generation + scan-to-add
├── QRScannerView.swift# camera QR scanner (AVFoundation)
└── ...                # SwiftUI views (Inbox, Agents, Sessions, Automations)

docs/
├── RELAY-DEPLOYMENT.md  # deployment, upgrade, troubleshooting
└── PRODUCTION-REVIEW.md # security review findings & fixes
```

## iOS App Installation

### Build & Install to a Real Device

```bash
# Build for device
xcodebuild -project apps/iosApp/iosApp.xcodeproj \
  -scheme iosApp \
  -configuration Debug \
  -destination 'id=YOUR_DEVICE_UDID' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  build

# Install
xcrun devicectl device install app --device YOUR_DEVICE_UDID \
  build/ios-device-derived/Build/Products/Debug-iphoneos/iosApp.app

# Launch
xcrun devicectl device process launch --device YOUR_DEVICE_UDID com.rayjun.nexus
```

After first install, trust the developer certificate:
**Settings → General → VPN & Device Management → Trust Developer Certificate**

### Relay URL on a Simulator/Device

The relay URL is set from the Pairing screen (Add Server). For automated
setup on a simulator, the UserDefaults key `relay_url` provides a default:

```bash
xcrun simctl spawn <UDID> defaults write com.rayjun.nexus relay_url -string "wss://<your-relay-domain>/relay"
```

DEBUG builds additionally allow `ws://127.0.0.1:9120` (local relay) for
simulator testing; Release builds require `wss://`.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| App stuck on "Waiting for agent…" | Agent not connected to the relay, or pairing code mismatch | Check agent logs; verify relay URL; re-pair with a fresh code |
| `join failed` | Same role already connected on the channel | Restart both sides; use a new pairing code |
| `peer not connected` | Peer dropped; the relay closed your connection | Both sides auto-reconnect; wait 3-5 s |
| Decrypt failures in agent logs | Key mismatch (pairing state desynced) | `nexus-agent stop` → `rm -rf ~/.hermes/mobile` → re-pair |
| `dashboard unavailable` | Dashboard not running or bad token | Verify the `HERMES_DASHBOARD_WS` value reaches the agent |
| `method not allowed` | Phone called a method outside the allowlist | Expected behavior; only listed methods are bridged |
| Camera won't open when scanning | Camera permission not granted | Grant camera access in iOS Settings → Nexus |

See [docs/RELAY-DEPLOYMENT.md](docs/RELAY-DEPLOYMENT.md) for the full troubleshooting guide, pairing flow details, and the relay wire protocol.

## Privacy Policy

Nexus does not collect, transmit, or store any personal data. All communication between the app and your self-hosted Hermes Gateway is end-to-end encrypted (X25519 + ChaCha20-Poly1305) and relayed through infrastructure you control. The relay operator sees only encrypted bytes and a channel ID. No analytics, no telemetry, no third-party SDKs. E2E keys are stored locally in iOS Keychain and never leave the device.

## Tech Stack

- **iOS**: SwiftUI, URLSession WebSocket, CryptoKit, AVFoundation (QR scanning), Keychain (Security framework)
- **Relay/Agent**: Python 3.10+, `websockets`, `pynacl` (X25519), `qrcode` (terminal pairing QR), stdlib HKDF-SHA256; TLS via Caddy + Let's Encrypt
- **Backend**: Hermes Agent Dashboard (WebSocket JSON-RPC, loopback bind)
- **LLM**: Hermes Agent → any supported model

## License

MIT © rayjun
