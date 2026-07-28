# Nexus

A native iOS app for managing AI agents powered by Hermes Agent. Connect directly to your Hermes gateway via WebSocket, chat with agents, browse sessions, and monitor tasks — all from your phone.

## Features

- **WebSocket Connection** — Direct JSON-RPC over WebSocket to Hermes gateway, no intermediate server needed
- **Session Management** — Browse and resume Hermes sessions with full timeline view
- **Agent Chat** — Send messages to Hermes agents with streaming response support
- **Real-time Events** — Live tool call updates, approval requests, and session status via WebSocket
- **Markdown Rendering** — Headings, bold, italic, code blocks with syntax highlighting, lists, blockquotes, links
- **Dark Mode** — Full dark mode support following system appearance
- **Secure Storage** — API keys stored in iOS Keychain
- **Auto-Reconnect** — Automatically reconnects on connection drops

## Requirements

- iOS 16.0+
- Xcode 15+ or Swift 5.9+
- Hermes Agent with dashboard server enabled
- Caddy (or any HTTPS reverse proxy) for TLS termination

## Architecture

```
┌──────────────┐     WSS/JSON-RPC     ┌──────────────────┐
│  Nexus iOS   │◄────────────────────►│  Caddy (TLS)     │
│  (SwiftUI)   │     wss://host:8444  │  :8444           │
└──────────────┘                      └────────┬─────────┘
                                               │ reverse proxy
                                               ▼
                                      ┌──────────────────┐
                                      │  Hermes Dashboard│
                                      │  (:8080 /api/ws) │
                                      └────────┬─────────┘
                                               │
                                               ▼
                                      ┌──────────────────┐
                                      │  Hermes Agent    │
                                      │  (LLM + tools)   │
                                      └──────────────────┘
```

- **iOS App** (SwiftUI): WebSocket JSON-RPC client, chat UI, session browser
- **Caddy**: TLS termination with self-signed certificates, reverse proxy to dashboard
- **Hermes Dashboard** (`hermes dashboard`): WebSocket endpoint `/api/ws` with JSON-RPC methods (`session.list`, `prompt.submit`, `approval.respond`, etc.)

## Connection Setup

Nexus connects directly to the Hermes Dashboard via WebSocket + JSON-RPC. No standalone backend is required. Below are the complete setup instructions for each deployment scenario.

### Why Dashboard Instead of API Server

Hermes runs two separate services:

| | Hermes API Server (8642) | Hermes Dashboard (8080) |
|---|---|---|
| Protocol | HTTP REST, OpenAI-compatible | WebSocket + JSON-RPC |
| Auth | `API_SERVER_KEY` (Bearer) | `HERMES_DASHBOARD_SESSION_TOKEN` (?token=) |
| Designed for | Third-party LLM frontends (Open WebUI, LibreChat…) | Hermes native clients (Desktop, Nexus) |
| Real-time events | None (request-response only) | `gateway.ready`, `session.info`, `message.delta` push events |
| Available RPC | `/v1/chat/completions`, `/v1/responses`, etc. | `session.list`, `session.resume`, `prompt.submit`, `cron.manage`, `approval.respond`, etc. |

Nexus is a Hermes native mobile client. It requires real-time event push, streaming output, cron management, and approval handling — all of which are only available through the Dashboard WebSocket. The API Server is designed for OpenAI-compatible frontends and does not support these capabilities.

### Two Different Keys

- **`API_SERVER_KEY`**: Bearer token for the API Server (port 8642) REST authentication. Long-lived, stored in `config.yaml`.
- **`HERMES_DASHBOARD_SESSION_TOKEN`**: Token for the Dashboard (port 8080) WebSocket `?token=` authentication. Process-level credential, invalidated when the Dashboard exits (can be fixed via environment variable).

Nexus uses **`HERMES_DASHBOARD_SESSION_TOKEN`**, not `API_SERVER_KEY`. These are completely independent authentication systems and are not interchangeable.

### Scenario 1: Local Simulator (Simplest)

The simulator runs on the same machine as the Dashboard. Direct loopback HTTP/WS — no Caddy or TLS needed.

#### 1. Generate a Dashboard Token

```bash
TOKEN=$(openssl rand -hex 16)
echo "HERMES_DASHBOARD_SESSION_TOKEN=$TOKEN" >> ~/.hermes/.env
echo "Your token: $TOKEN"
```

#### 2. Start the Dashboard

```bash
export HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN"
hermes dashboard --port 8080 --host 127.0.0.1 --insecure
```

- `--host 127.0.0.1` — bind to loopback, no external access needed
- `--insecure` — use token-based auth without OAuth gate

Verify:

```bash
curl -s http://127.0.0.1:8080/api/status | python3 -m json.tool
```

Should return `"gateway_state": "running"` and `"overall": "ok"`.

#### 3. Connect from Nexus

In DEBUG mode the app auto-fills `http://127.0.0.1:8080` and the token, then connects automatically. To connect manually:

- **GATEWAY**: `http://127.0.0.1:8080`
- **API KEY**: the token you generated
- Tap **Connect**

The app automatically converts `http://` to `ws://` and appends `/api/ws?token=YOUR_TOKEN`.

### Scenario 2: Remote Device via Caddy WSS

iOS 26+ requires TLS for all network connections. A remote device needs Caddy as an HTTPS/WSS reverse proxy.

```
iPhone (wss://) ←→ Caddy (TLS :8444) ←→ Hermes Dashboard (HTTP :8080)
```

#### 1. Generate Token and Start Dashboard on the Server

```bash
TOKEN=$(openssl rand -hex 16)
echo "HERMES_DASHBOARD_SESSION_TOKEN=$TOKEN" >> ~/.hermes/.env
export HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN"
hermes dashboard --port 8080 --host 127.0.0.1 --insecure
```

The Dashboard binds to loopback; Caddy handles external TLS.

#### 2. Install and Configure Caddy

```bash
# Ubuntu/Debian
sudo apt install caddy

# macOS
brew install caddy
```

Edit the Caddyfile (replace the IP with your server's address):

```
https://YOUR_SERVER_IP:8444 {
    reverse_proxy 127.0.0.1:8080
    tls internal
}
```

- `tls internal` — Caddy auto-generates a self-signed certificate
- WebSocket connections are transparently proxied

Start Caddy:

```bash
sudo systemctl restart caddy
# Or run manually for testing
caddy run --config /etc/caddy/Caddyfile
```

Verify the proxy:

```bash
curl -sk https://YOUR_SERVER_IP:8444/api/status | python3 -m json.tool
```

#### 3. Connect from Nexus

- **GATEWAY**: `https://YOUR_SERVER_IP:8444`
- **API KEY**: the `HERMES_DASHBOARD_SESSION_TOKEN` value you generated
- Tap **Connect**

The app automatically:
1. Converts `https://` → `wss://`
2. Appends `/api/ws?token=YOUR_TOKEN`
3. Caddy terminates TLS and proxies to `ws://127.0.0.1:8080/api/ws?token=YOUR_TOKEN`
4. Dashboard validates the token and accepts the connection
5. The app accepts self-signed certificates via `InsecureURLSessionDelegate`

### Scenario 3: Tailscale Direct (Recommended, Simplest)

If both your device and server are on the same Tailscale network, you can connect directly without Caddy.

#### 1. Start Dashboard Bound to the Tailscale Interface

```bash
export HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN"
hermes dashboard --port 8080 --host 0.0.0.0 --insecure
```

- `--host 0.0.0.0` — allow access from the Tailscale interface
- The Tailscale network itself is the authentication boundary; no additional TLS needed

#### 2. Connect from Nexus

- **GATEWAY**: `http://YOUR_TAILSCALE_IP:8080`
- **API KEY**: the token you generated
- Tap **Connect**

> **Note**: Tailscale provides an encrypted tunnel, so HTTP/WS is sufficient at the application layer. ATS allows arbitrary loads. However, iOS ATS may still restrict non-localhost HTTP connections in some cases — if the connection fails, use Caddy to provide HTTPS instead.

### Authentication How It Works

Dashboard WebSocket authentication logic (from `web_server.py`, `_ws_auth_reason`):

1. **Loopback / `--insecure` mode** (Scenarios 1 & 3):
   - Client sends `?token=<HERMES_DASHBOARD_SESSION_TOKEN>`
   - Server compares with `hmac.compare_digest` (constant-time)
   - Match → accept; mismatch → close with code 4401

2. **Gated mode** (public bind without `--insecure`):
   - The `?token=` path is unconditionally rejected
   - Replaced with single-use tickets (30s TTL) or an internal credential
   - **Nexus does not support this mode** — ensure Dashboard runs with `--insecure` or loopback + Caddy

3. **Why not use `API_SERVER_KEY` directly**:
   - The Dashboard does not check `API_SERVER_KEY`; they are independent auth systems
   - `API_SERVER_KEY` is a long-lived credential with broader scope — more damaging if leaked
   - Dashboard token is process-level, auto-rotates on restart, with narrower permissions

### Persistent Service (Optional)

For production, run the Dashboard as a systemd service:

```ini
[Unit]
Description=Hermes Dashboard
After=network.target

[Service]
Type=simple
Environment=HERMES_DASHBOARD_SESSION_TOKEN=YOUR_TOKEN
ExecStart=/usr/local/bin/hermes dashboard --port 8080 --host 127.0.0.1 --insecure
Restart=always
RestartSec=5
User=your-username

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable hermes-dashboard
sudo systemctl start hermes-dashboard
```

### Verification Checklist

After setup, verify in order:

1. **Dashboard running**: `curl -s http://127.0.0.1:8080/api/status` → `"gateway_state": "running"`
2. **Caddy proxy** (remote scenario): `curl -sk https://YOUR_IP:8444/api/status` → same result
3. **Token correct**: App's API KEY matches `HERMES_DASHBOARD_SESSION_TOKEN` in `~/.hermes/.env`
4. **WebSocket connected**: App logs show `gateway.ready` and `session.list` RPC success
5. **Data loaded**: Sessions tab shows session list, Agents tab shows agent list

## iOS App Installation

### Build & Run (Simulator)

```bash
cd apps/iosApp
open iosApp.xcodeproj
# In Xcode: select iosApp scheme, choose simulator, Run (⌘R)
```

### Install to Simulator (CLI)

```bash
# Build
xcodebuild -project apps/iosApp/iosApp.xcodeproj \
  -scheme iosApp \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

# Install and launch
SIM_ID=$(xcrun simctl list devices booted | grep "iPhone" | grep -oE '[0-9A-F-]{36}')
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/iosApp-*/Build/Products/Debug-iphonesimulator/iosApp.app -maxdepth 0 | head -1)
xcrun simctl install "$SIM_ID" "$APP_PATH"
xcrun simctl launch "$SIM_ID" com.rayjun.nexus
```

### Install to Real Device

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

## Troubleshooting

### "Cannot reach gateway"

- Verify Dashboard is running: `curl -s http://127.0.0.1:8080/api/status`
- Verify Caddy is running (remote scenario): `sudo systemctl status caddy`
- Check Tailscale connectivity: `tailscale status`
- Ensure the App's API KEY matches `HERMES_DASHBOARD_SESSION_TOKEN` in `~/.hermes/.env`

### "Connection timed out"

- Check firewall rules allow port 8444
- Verify Caddy is listening: `ss -tlnp | grep 8444`
- Test from another device: `curl -sk https://YOUR_IP:8444/api/status`

### "WebSocket immediately closes (code 4401)"

- 4401 = authentication failure
- Ensure the token value matches exactly — no extra spaces or newlines
- Ensure Dashboard started with `--insecure` (in gated mode, `?token=` is rejected)
- Check that `HERMES_DASHBOARD_SESSION_TOKEN` in `~/.hermes/.env` matches what was used at startup

### "code = 4001 session not found"

- 4001 = historical session cannot be accessed directly
- The app handles this via `session.resume` — if it still occurs, ensure your Hermes Agent version supports the `session.resume` RPC

### "Invalid code signature"

After installing on a real device, trust the developer:
**Settings → General → VPN & Device Management → Trust Developer Certificate**

### WebSocket connection drops

The app has built-in auto-reconnect with 30-second ping keepalive. If it keeps dropping:
- Check Dashboard stability: `journalctl -u hermes-dashboard -f`
- Check Caddy logs: `journalctl -u caddy -f`

## Privacy Policy

Nexus does not collect, transmit, or store any personal data. All communication occurs directly between the app and your self-hosted Hermes Gateway via encrypted WebSocket (WSS). No analytics, no telemetry, no third-party SDKs. API keys are stored locally in iOS Keychain and never leave the device.

## Tech Stack

- **iOS**: SwiftUI, URLSession WebSocket, Keychain (Security framework)
- **Backend**: Hermes Agent dashboard server (WebSocket JSON-RPC)
- **TLS**: Caddy reverse proxy with self-signed certificates
- **LLM**: Hermes Agent → any OpenAI-compatible model

## License

MIT © rayjun