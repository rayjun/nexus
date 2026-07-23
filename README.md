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

## Server-Side Setup

### 1. Start Hermes Dashboard

The dashboard server provides the `/api/ws` WebSocket endpoint that Nexus connects to:

```bash
hermes dashboard --port 8080 --host 0.0.0.0 --insecure
```

The `--insecure` flag allows token-based auth without OAuth (suitable for Tailscale/private networks).

Verify it's running:

```bash
curl -s http://127.0.0.1:8080/api/status
```

### 2. Set API Server Key

The WebSocket connection authenticates with a token. Set it in Hermes:

```bash
echo 'API_SERVER_KEY=your-secret-key-here' >> ~/.hermes/.env
hermes gateway restart
```

### 3. Set up Caddy HTTPS Reverse Proxy

iOS 26+ requires TLS for all network connections. Caddy provides automatic self-signed certificates.

#### Install Caddy

```bash
# Ubuntu/Debian
sudo apt install caddy

# macOS
brew install caddy
```

#### Configure Caddy

```bash
sudo nano /etc/caddy/Caddyfile
```

Add this configuration (replace `100.91.132.51` with your server's Tailscale IP):

```
https://100.91.132.51:8444 {
    reverse_proxy 127.0.0.1:8080
    tls internal
}
```

- `tls internal` — Caddy generates and manages a self-signed certificate automatically
- The app's `InsecureURLSessionDelegate` accepts self-signed certs on the iOS side

#### Start Caddy

```bash
sudo systemctl restart caddy

# Or run manually (for testing)
caddy run --config /etc/caddy/Caddyfile
```

Verify the proxy works:

```bash
# Should return a valid response (not a connection error)
curl -sk https://100.91.132.51:8444/api/status
```

### 4. Connect from iPhone

In the Nexus app:

1. Enter **Gateway URL**: `https://100.91.132.51:8444`
2. Enter **API Key**: the value of `API_SERVER_KEY` from `~/.hermes/.env`
3. Tap **Connect**

The app automatically:
- Converts `https://` → `wss://`
- Appends `/api/ws?token=YOUR_KEY`
- Accepts self-signed certificates via `InsecureURLSessionDelegate`

### 5. (Optional) Run Dashboard as a Service

For production, run the dashboard as a persistent service:

#### systemd (Linux)

Create `/etc/systemd/system/hermes-dashboard.service`:

```ini
[Unit]
Description=Hermes Dashboard
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hermes dashboard --port 8080 --host 0.0.0.0 --insecure
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

- Verify Caddy is running: `sudo systemctl status caddy`
- Verify dashboard is running: `curl http://127.0.0.1:8080/api/status`
- Check Tailscale connectivity: `tailscale status`
- Ensure the API key matches `~/.hermes/.env`

### "Connection timed out"

- Check firewall rules allow port 8444
- Verify Caddy is listening: `ss -tlnp | grep 8444`
- Test from another machine: `curl -sk https://YOUR_IP:8444/api/status`

### "Invalid code signature"

After installing on a real device, trust the developer:
**Settings → General → VPN & Device Management → Trust Developer Certificate**

### WebSocket connection drops

The app has built-in auto-reconnect with 30-second ping keepalive. If it keeps dropping:
- Check server stability: `journalctl -u hermes-dashboard -f`
- Check Caddy logs: `journalctl -u caddy -f`

## Running Tests

```bash
cd /path/to/hermes-mobile
python3.11 -m pytest tests/ -q
```

## Privacy Policy

Nexus does not collect, transmit, or store any personal data. All communication occurs directly between the app and your self-hosted Hermes Gateway via encrypted WebSocket (WSS). No analytics, no telemetry, no third-party SDKs. API keys are stored locally in iOS Keychain and never leave the device.

## Tech Stack

- **iOS**: SwiftUI, URLSession WebSocket, Keychain (Security framework)
- **Backend**: Hermes Agent dashboard server (WebSocket JSON-RPC)
- **TLS**: Caddy reverse proxy with self-signed certificates
- **LLM**: Hermes Agent → any OpenAI-compatible model

## License

MIT © rayjun