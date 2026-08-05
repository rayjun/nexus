# Nexus

A native iOS app for managing AI agents powered by Hermes Agent. Connect to your Hermes gateway over an E2E-encrypted relay channel, chat with agents, browse sessions, and monitor tasks — all from your phone.

## Features

- **Relay Connection** — E2E-encrypted (X25519 + ChaCha20-Poly1305) WebSocket through a lightweight public relay; no inbound ports on the agent server, no TLS certificate management on devices
- **Pairing** — 6-digit pairing code, single-use; keys persist for automatic reconnect
- **Session Management** — Browse and resume Hermes sessions with full timeline view
- **Agent Chat** — Send messages to Hermes agents with streaming response support
- **Real-time Events** — Live tool call updates, approval requests, and session status
- **Markdown Rendering** — Headings, bold, italic, code blocks with syntax highlighting, lists, blockquotes, links
- **Dark Mode** — Full dark mode support following system appearance
- **Secure Storage** — E2E keys stored in iOS Keychain

## Requirements

- iOS 16.0+
- Xcode 15+ or Swift 5.9+
- Hermes Agent v0.19.0+ with dashboard server enabled
- A public relay server (see [Relay Deployment](docs/RELAY-DEPLOYMENT.md))

## Architecture

```
┌──────────────┐     WSS (outbound)    ┌──────────┐     WSS (outbound)    ┌──────────────┐
│ Hermes Agent │ ←──────────────────→  │  Relay   │  ←──────────────────→  │  Nexus App   │
│ (user server)│   E2E encrypted      │ (public)  │   E2E encrypted       │ (iOS/Android) │
└──────────────┘                      └──────────┘                      └──────────────┘
```

- **Relay Server** (`relay/relay_server.py`): public server behind Caddy + Let's Encrypt. Routes encrypted bytes between paired endpoints. Never sees plaintext.
- **Agent Client** (`relay/relay_agent.py`): runs next to Hermes Gateway, bridges E2E-encrypted JSON-RPC to the real Dashboard WebSocket. Connects outbound — opens no inbound ports.
- **iOS App** (SwiftUI): `RelayClient.swift` + `E2ECrypto.swift` (CryptoKit), pairing UI + encrypted JSON-RPC.

Full deployment instructions: [docs/RELAY-DEPLOYMENT.md](docs/RELAY-DEPLOYMENT.md)

> **Legacy direct connection** (Nginx/Caddy → Dashboard `/api/ws?token=`) is documented below for reference. New deployments should use the Relay + E2E architecture above.

## Connection Setup

> **Note for legacy direct connection.** New deployments: see [Relay Deployment](docs/RELAY-DEPLOYMENT.md) — pair once with a 6-digit code, no URLs or tokens to configure.

Nexus connects to the Hermes Dashboard via WebSocket + JSON-RPC. The Dashboard must bind to loopback (`127.0.0.1`) so that the session token authentication works. A reverse proxy (Nginx or Caddy) provides TLS termination for remote device access.

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

### Important: Dashboard Must Bind to Loopback

Since Hermes v0.19.0, the `--insecure` flag is a **no-op** for non-loopback binds. The auth gate is determined solely by the bind host:

- **`127.0.0.1` / `localhost` / `::1`** → loopback mode, `?token=` authentication works
- **Any other address** (`0.0.0.0`, Tailscale IP, LAN IP) → gated mode, forces OAuth or password auth, `?token=` is rejected

This means the Dashboard **must** bind to `127.0.0.1`. External access is provided by a reverse proxy (Nginx or Caddy) that terminates TLS and forwards to the loopback Dashboard. This is the only supported topology for Nexus.

### Step 1: Generate Dashboard Token and Start Dashboard

On the server:

```bash
TOKEN=$(openssl rand -hex 16)
echo "HERMES_DASHBOARD_SESSION_TOKEN=$TOKEN" >> ~/.hermes/.env
export HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN"
hermes dashboard --port 9119 --host 127.0.0.1
```

- `--host 127.0.0.1` — bind to loopback (required for token auth)
- `--insecure` is not needed and is ignored for loopback binds
- Port `9119` is an example; any free port works

Verify:

```bash
curl -s http://127.0.0.1:9119/api/status | python3 -m json.tool
```

Should return `"gateway_state": "running"` and `"overall": "ok"`.

### Step 2: Configure Reverse Proxy (TLS)

iOS 26+ requires TLS for all network connections. Use Nginx or Caddy to terminate TLS and proxy to the loopback Dashboard.

#### Option A: Nginx

```nginx
server {
    listen 8444 ssl;
    server_name YOUR_SERVER_IP;

    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://127.0.0.1:9119;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

For self-signed certificates, generate one:

```bash
openssl req -x509 -newkey rsa:4096 -keyout /path/to/key.pem \
  -out /path/to/cert.pem -days 365 -nodes \
  -subj "/CN=YOUR_SERVER_IP"
```

Start Nginx:

```bash
sudo nginx -t && sudo systemctl restart nginx
```

#### Option B: Caddy

```
https://YOUR_SERVER_IP:8444 {
    reverse_proxy 127.0.0.1:9119
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

#### Verify the Proxy

```bash
curl -sk https://YOUR_SERVER_IP:8444/api/status | python3 -m json.tool
```

Should return the same result as the loopback curl in Step 1.

### Step 3: Connect from Nexus

In the Nexus app:

- **GATEWAY**: `https://YOUR_SERVER_IP:8444`
- **API KEY**: the `HERMES_DASHBOARD_SESSION_TOKEN` value you generated
- Tap **Connect**

The app automatically:
1. Converts `https://` → `wss://`
2. Appends `/api/ws?token=YOUR_TOKEN`
3. Nginx/Caddy terminates TLS and proxies to `ws://127.0.0.1:9119/api/ws?token=YOUR_TOKEN`
4. Dashboard validates the token (loopback mode) and accepts the connection
5. The app trusts self-signed certificates via `URLSessionDelegate` serverTrust challenge handling

### Authentication How It Works

Dashboard WebSocket authentication logic (from `web_server.py`, `_ws_auth_reason`):

1. **Loopback mode** (`--host 127.0.0.1`):
   - Client sends `?token=<HERMES_DASHBOARD_SESSION_TOKEN>`
   - Server compares with `hmac.compare_digest` (constant-time)
   - Match → accept; mismatch → close with code 4401

2. **Gated mode** (any non-loopback bind, including `0.0.0.0` and Tailscale IPs):
   - `?token=` is unconditionally rejected (since v0.19.0, `--insecure` no longer bypasses this)
   - Replaced with single-use tickets (30s TTL) or an internal credential
   - **Nexus does not support this mode** — always bind Dashboard to `127.0.0.1` and use a reverse proxy

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
ExecStart=/usr/local/bin/hermes dashboard --port 9119 --host 127.0.0.1
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

1. **Dashboard running**: `curl -s http://127.0.0.1:9119/api/status` → `"gateway_state": "running"`
2. **Reverse proxy**: `curl -sk https://YOUR_IP:8444/api/status` → same result
3. **Token correct**: App's API KEY matches `HERMES_DASHBOARD_SESSION_TOKEN` in `~/.hermes/.env`
4. **WebSocket connected**: App logs show `gateway.ready` and `session.list` RPC success
5. **Data loaded**: Sessions tab shows session list, Agents tab shows agent list

## iOS App Installation

### Build & Install to Real Device

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

- Verify Dashboard is running: `curl -s http://127.0.0.1:9119/api/status`
- Verify reverse proxy is running: `sudo systemctl status nginx` (or `caddy`)
- Ensure the App's API KEY matches `HERMES_DASHBOARD_SESSION_TOKEN` in `~/.hermes/.env`

### "Connection timed out"

- Check firewall rules allow port 8444
- Verify Nginx/Caddy is listening: `ss -tlnp | grep 8444`
- Test from another device: `curl -sk https://YOUR_IP:8444/api/status`

### "WebSocket immediately closes (code 4401)"

- 4401 = authentication failure
- Ensure the token value matches exactly — no extra spaces or newlines
- Ensure Dashboard is bound to `127.0.0.1` (non-loopback binds force gated mode and reject `?token=`)
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
- Check reverse proxy logs: `journalctl -u nginx -f` (or `journalctl -u caddy -f`)

## Privacy Policy

Nexus does not collect, transmit, or store any personal data. All communication occurs directly between the app and your self-hosted Hermes Gateway via encrypted WebSocket (WSS). No analytics, no telemetry, no third-party SDKs. API keys are stored locally in iOS Keychain and never leave the device.

## Tech Stack

- **iOS**: SwiftUI, URLSession WebSocket, Keychain (Security framework)
- **Backend**: Hermes Agent dashboard server (WebSocket JSON-RPC, loopback bind)
- **TLS**: Nginx or Caddy reverse proxy with self-signed certificates
- **LLM**: Hermes Agent → any OpenAI-compatible model

## License

MIT © rayjun