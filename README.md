# Nexus

A native iOS app for managing AI agents powered by [Hermes Agent](https://github.com/NousResearch/hermes-agent). Connect to your Hermes gateway over an E2E-encrypted relay channel, chat with agents, browse sessions, and monitor tasks — all from your phone. Zero inbound ports on your server, zero certificate management on your device.

## Features

- **E2E-Encrypted Relay** — X25519 key agreement + ChaCha20-Poly1305 AEAD over a lightweight public relay. The relay only sees ciphertext and a channel ID; it never sees message content.
- **6-Digit Pairing** — Pair once with a short code; keys persist for automatic reconnect (0-RTT).
- **Session Management** — Browse and resume Hermes sessions with a full timeline view.
- **Agent Chat** — Send prompts to Hermes agents, approve/deny tool approvals, interrupt running sessions.
- **Cron & Automation** — View and manage Hermes cron jobs from your phone.
- **Markdown Rendering** — Headings, bold, italic, code blocks with syntax highlighting, lists, blockquotes, links.
- **Dark Mode** — Full dark mode support following system appearance.
- **Secure Storage** — E2E keys and pairing state stored in iOS Keychain.

## Architecture

```
┌──────────────┐     WSS (outbound)    ┌──────────┐     WSS (outbound)    ┌──────────────┐
│ Hermes Agent │ ←──────────────────→  │  Relay   │  ←──────────────────→  │  Nexus App   │
│ (user server)│   E2E encrypted      │ (public)  │   E2E encrypted       │   (iOS)      │
└──────────────┘                      └──────────┘                      └──────────────┘
```

- **Relay Server** (`relay/relay_server.py`): a ~200-line public WebSocket relay behind any TLS terminator (Caddy + Let's Encrypt). It routes encrypted bytes between paired endpoints and never parses message content.
- **Agent Client** (`relay/relay_agent.py`): runs next to your Hermes Gateway and bridges E2E-encrypted JSON-RPC to the real Dashboard WebSocket. It connects **outbound** — your server opens no inbound ports.
- **iOS App** (SwiftUI): `RelayClient.swift` + `E2ECrypto.swift` (CryptoKit) implement pairing, encryption, and JSON-RPC over the relay.

Security properties:

- **Confidentiality** — the relay operator cannot read traffic (direction-separated ChaChaPoly keys, per-session nonce counters with replay protection).
- **Authenticity** — AEAD tags prevent tampering; replay of captured messages is rejected via monotonic sequence validation.
- **Least privilege** — the agent enforces a method allowlist (no `config.get` from the phone); the relay rejects data from unjoined sockets and rate-limits abuse.

## Requirements

- iOS 16.0+
- Xcode 15+ / Swift 5.9+
- Hermes Agent v0.19.0+ with the Dashboard server running on loopback
- A public relay server (one-time setup, see below)

## Getting Started

Full deployment instructions: **[docs/RELAY-DEPLOYMENT.md](docs/RELAY-DEPLOYMENT.md)**

```
1. Deploy the relay stack (one-time):
     bash relay/deploy-relay.sh install <your-relay-domain>

2. Start the agent client in pairing mode on your server:
     cd ~/nexus-relay
     HERMES_DASHBOARD_WS='ws://127.0.0.1:9119/api/ws?token=YOUR_TOKEN' \
       python3 relay_agent.py --relay wss://<your-relay-domain>/relay \
       --pair --code 123456

3. In the Nexus app: enter the 6-digit code → Dashboard.
```

After pairing, the app reconnects automatically with the stored keys — no URL, token, or certificate configuration on the device.

## Repository Layout

```
relay/
├── relay_server.py    # public WebSocket relay (routes encrypted bytes)
├── relay_agent.py     # agent-side client (pairing + Dashboard bridge)
├── crypto.py          # X25519 + ChaCha20-Poly1305 + HKDF (pynacl)
├── deploy-relay.sh    # install/upgrade script for the server
└── README.md

apps/iosApp/iosApp/
├── RelayClient.swift  # WebSocket client: pairing + E2E JSON-RPC
├── E2ECrypto.swift    # CryptoKit implementation of the same crypto
├── PairingView.swift  # 6-digit pairing UI
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

### Point the App at Your Relay

The relay URL is read from UserDefaults key `relay_url`. DEBUG builds default to `ws://127.0.0.1:9120` (simulator); Release builds default to `wss://relay.example.com/relay`. Override it on a device/simulator:

```bash
xcrun simctl spawn <UDID> defaults write com.rayjun.nexus relay_url -string "wss://<your-relay-domain>/relay"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| App stuck on "Waiting for agent…" | Agent not connected to the relay, or pairing code mismatch | Check agent logs; verify `--relay` URL; re-pair with a fresh code |
| `join failed` | Same role already connected on the channel | Restart both sides; use a new pairing code |
| `peer not connected` | Peer dropped; the relay closed your connection | Both sides auto-reconnect; wait 3-5 s |
| Decrypt failures in agent logs | Key mismatch (pairing state desynced) | `rm -rf ~/.hermes/mobile` on the agent; re-pair |
| `dashboard unavailable` | Dashboard not running or bad token | Verify `ws://127.0.0.1:9119/api/ws?token=...` with a Python WebSocket client first |
| `method not allowed` | Phone called a method outside the allowlist | Expected behavior; only listed methods are bridged |

See [docs/RELAY-DEPLOYMENT.md](docs/RELAY-DEPLOYMENT.md) for the full troubleshooting guide, pairing flow details, and the relay wire protocol.

## Privacy Policy

Nexus does not collect, transmit, or store any personal data. All communication between the app and your self-hosted Hermes Gateway is end-to-end encrypted (X25519 + ChaCha20-Poly1305) and relayed through infrastructure you control. The relay operator sees only encrypted bytes and a channel ID. No analytics, no telemetry, no third-party SDKs. E2E keys are stored locally in iOS Keychain and never leave the device.

## Tech Stack

- **iOS**: SwiftUI, URLSession WebSocket, CryptoKit, Keychain (Security framework)
- **Relay**: Python 3.11+, `websockets`, `pynacl`, `cryptography`; TLS via Caddy + Let's Encrypt
- **Backend**: Hermes Agent Dashboard (WebSocket JSON-RPC, loopback bind)
- **LLM**: Hermes Agent → any supported model

## License

MIT © rayjun
