# Nexus

A native iOS app for managing AI agents powered by Hermes Agent. Create persistent agents, chat with them via Hermes LLM, manage agent servers, and monitor sessions — all from your phone.

## Features

- **Agent Server Management** — Add, edit, and remove Hermes agent servers with custom names and URLs
- **Persistent Agents** — Create AI agents with custom icons, names, and descriptions. Each agent maintains conversation context via Hermes sessions
- **Real LLM Chat** — Messages route through Hermes API server (OpenAI-compatible endpoint), with session continuity via `X-Hermes-Session-Id`
- **Session Timeline** — View Hermes session execution timelines with tool calls, thinking blocks, and results
- **Inbox** — Active tasks (running Hermes sessions) and pending approvals
- **Cron Jobs** — View scheduled tasks from Hermes
- **Markdown Rendering** — Full markdown support in chat: headings, bold, italic, inline code, code blocks with syntax highlighting, ordered/unordered lists, blockquotes, dividers
- **Code Highlighting** — Syntax highlighting for code blocks (Swift, Python, Rust, Go, C/C++, Bash) with copy button and horizontal scroll
- **Toast Notifications** — Success/error feedback for all operations
- **Secure Storage** — Device tokens stored in iOS Keychain
- **Auto-Reconnect** — Automatically re-pairs with gateway on token expiration

## Requirements

- iOS 16.0+
- Xcode 15+ or Swift 5.9+
- Python 3.11+
- Hermes Agent with API server platform enabled

## Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Nexus iOS   │────▶│  Mobile Gateway   │────▶│  Hermes API     │
│  (SwiftUI)   │HTTP │  (FastAPI:8765)   │HTTP │  Server (8642)  │
└──────────────┘     └──────────────────┘     └─────────────────┘
                            │                        │
                            ▼                        ▼
                     ┌──────────────┐        ┌──────────────┐
                     │  state.db    │        │  LLM (Ollama │
                     │  (SQLite)    │        │  Cloud/API)  │
                     └──────────────┘        └──────────────┘
```

- **iOS App** (SwiftUI): Connect view, agent server list, agent chat, session timeline, inbox
- **Mobile Gateway** (FastAPI, port 8765): Pairing, device auth, CRUD for agents/sessions/cron/approvals. Reads/writes Hermes `state.db` directly
- **Hermes API Server** (port 8642): OpenAI-compatible `/v1/chat/completions` endpoint with session continuity. Part of Hermes Agent core

## Server-Side Setup

Nexus needs two backend services running: the **Mobile Gateway** (this repo) and the **Hermes API Server** (part of Hermes Agent).

### 1. Install Hermes Agent

```bash
# Using pipx (recommended)
pipx install hermes-agent

# Or if already installed, ensure it's up to date
pipx upgrade hermes-agent
```

Verify installation:

```bash
hermes --version
```

### 2. Enable Hermes API Server

The API server is what Nexus calls to get LLM responses. It runs on port 8642 by default.

```bash
# Enable the API server platform
hermes config set gateway.platforms.api_server.enabled true

# Set the API server key (used for authentication)
echo 'API_SERVER_KEY=your-secret-key-here' >> ~/.hermes/.env

# Restart Hermes gateway to apply
hermes gateway restart
```

Verify the API server is running:

```bash
# Should return 401 (auth required = server is up)
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8642/v1/models

# With auth — should return model list
curl http://127.0.0.1:8642/v1/models \
  -H "Authorization: Bearer your-secret-key-here"
```

### 3. Set Up the Mobile Gateway

The Mobile Gateway is a standalone FastAPI server included in this repo. It handles device pairing, agent CRUD, session management, and proxies chat messages to the Hermes API server.

#### 3a. Install Dependencies

```bash
cd /path/to/hermes-mobile

# Install dependencies (Python 3.11+ required)
pip3.11 install fastapi uvicorn httpx pydantic pyyaml
```

Dependencies:

| Package | Purpose |
|---------|---------|
| `fastapi` | Web framework for the gateway API |
| `uvicorn` | ASGI server |
| `httpx` | HTTP client to call Hermes API server |
| `pydantic` | Data validation / models |
| `pyyaml` | Config parsing (`~/.hermes/config.yaml`) |

#### 3b. Start the Mobile Gateway

**Option A: Direct run (foreground)**

```bash
cd /path/to/hermes-mobile

HERMES_MOBILE_USE_STATE_DB=1 \
  python3.11 -m uvicorn \
  backend_plugin.hermes_mobile.server:app \
  --host 0.0.0.0 \
  --port 8765
```

**Option B: Background with nohup**

```bash
HERMES_MOBILE_USE_STATE_DB=1 \
  nohup python3.11 -m uvicorn \
  backend_plugin.hermes_mobile.server:app \
  --host 0.0.0.0 --port 8765 \
  > /tmp/mobile-gateway.log 2>&1 &
```

**Option C: launchd persistent service**

Create `~/Library/LaunchAgents/com.rayjun.nexus.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.rayjun.nexus</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/python3.11</string>
    <string>-m</string>
    <string>uvicorn</string>
    <string>backend_plugin.hermes_mobile.server:app</string>
    <string>--host</string>
    <string>0.0.0.0</string>
    <string>--port</string>
    <string>8765</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/path/to/hermes-mobile</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERMES_MOBILE_USE_STATE_DB</key>
    <string>1</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/mobile-gateway.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/mobile-gateway.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.rayjun.nexus.plist
```

#### 3c. Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `HERMES_MOBILE_USE_STATE_DB` | **Yes** | — | Set to `1` to use Hermes `state.db` (real data). Without this, the gateway uses a mock store with no persistence |
| `HERMES_MOBILE_STATE_DB` | No | `~/.hermes/state.db` | Override path to the Hermes state database |
| `HERMES_MOBILE_BASE_URL` | No | `http://127.0.0.1:8765` | The gateway URL shown in pairing QR code and agent server list |
| `HERMES_MOBILE_AGENT_NAME` | No | System hostname | Display name for the default agent server |
| `HERMES_API_URL` | No | `http://127.0.0.1:8642` | Hermes API server URL (for LLM calls) |

Note: Live approval forwarding is enabled by default — no environment variable needed.

#### 3d. Verify the Gateway

```bash
curl http://127.0.0.1:8765/mobile/v1/status | python3 -m json.tool
```

Expected output:

```json
{
  "node_id": "your-machine",
  "node_name": "your-machine",
  "status": "online",
  "gateway_ready": true,
  "model": {
    "provider": "ollama-cloud",
    "model": "glm-5.2"
  },
  ...
}
```

```bash
# Health check
curl http://127.0.0.1:8765/health
# {"status":"ok","service":"nexus-gateway","version":"0.1.0"}
```

### 5. Connect from iPhone

The gateway must be reachable from your iPhone via **HTTPS** (iOS 26+ requires TLS).

#### Set up Caddy reverse proxy (recommended)

Caddy automatically generates self-signed certificates. Install and configure:

```bash
# Install Caddy (Ubuntu/Debian)
sudo apt install caddy

# Edit Caddyfile
sudo nano /etc/caddy/Caddyfile
```

Add this configuration (replace `100.91.132.51` with your Tailscale IP):

```
https://100.91.132.51:8443 {
    reverse_proxy 127.0.0.1:8642
    tls internal
}
```

```bash
sudo systemctl restart caddy
```

This proxies HTTPS :8443 → HTTP :8642 (Hermes API server) with a self-signed cert.

#### Set up Hermes Dashboard with WebSocket

The iOS app connects via WebSocket (`/api/ws`). Start the dashboard server:

```bash
hermes dashboard --port 8080 --host 0.0.0.0 --insecure
```

Add a second Caddy route for WebSocket:

```
https://100.91.132.51:8444 {
    reverse_proxy 127.0.0.1:8080
    tls internal
}
```

#### In the Nexus app

Enter:
- **Gateway URL**: `https://100.91.132.51:8444` (dashboard with `/api/ws`)
- **API Key**: Your `API_SERVER_KEY` from `~/.hermes/.env`

The app auto-converts `https://` → `wss://` and appends `/api/ws?token=YOUR_KEY`.

## iOS App Installation

### Build & Run

```bash
cd apps/iosApp
open iosApp.xcodeproj
# In Xcode: select iosApp scheme, choose simulator, Run (⌘R)
```

### Install to Simulator (CLI)

```bash
cd /path/to/hermes-mobile

# Build
xcodebuild -project apps/iosApp/iosApp.xcodeproj \
  -scheme iosApp \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

# Install and launch
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/iosApp-*/Build/Products/Debug-iphonesimulator/iosApp.app -maxdepth 0 | head -1)

# Get simulator ID
SIM_ID=$(xcrun simctl list devices booted | grep "iPhone" | grep -oE '[0-9A-F-]{36}')

xcrun simctl install "$SIM_ID" "$APP_PATH"
xcrun simctl launch "$SIM_ID" com.rayjun.nexus
```

## Troubleshooting

### Agent chat returns "Internal Server Error"

The mobile gateway process may be stale. Restart it:

```bash
# Find and kill old process
ps aux | grep 'hermes_mobile.server' | grep -v grep | awk '{print $2}' | xargs kill

# Restart with latest code
cd /path/to/hermes-mobile
HERMES_MOBILE_USE_STATE_DB=1 \
  /tmp/hermes-mobile-venv311/bin/python -m uvicorn \
  backend_plugin.hermes_mobile.server:app \
  --host 0.0.0.0 --port 8765
```

### "API_SERVER_KEY not set in ~/.hermes/.env"

The Hermes API server requires a key. Set it and restart:

```bash
echo 'API_SERVER_KEY=your-secret-key' >> ~/.hermes/.env
hermes gateway restart
```

### "Hermes API server is not running"

The API server on port 8642 is down. Start Hermes:

```bash
hermes gateway restart
# Verify
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8642/v1/models
```

### Simulator can't connect to gateway

The iOS Simulator shares the Mac's network, so `127.0.0.1:8765` works for local development. For a physical device, use Tailscale or your Mac's LAN IP.

## Running Tests

```bash
cd /path/to/hermes-mobile
python -m pytest tests/ -q
```

## Privacy Policy

Nexus does not collect, transmit, or store any personal data. All communication occurs directly between the app and your self-hosted Hermes Gateway on your local network or Tailscale VPN. No analytics, no telemetry, no third-party SDKs. Device pairing tokens are stored locally in iOS Keychain and never leave the device.

## Tech Stack

- **iOS**: SwiftUI, URLSession, Keychain (Security framework)
- **Backend**: Python 3.11, FastAPI, SQLite (state.db), httpx
- **LLM**: Hermes API server → any OpenAI-compatible model

## License

MIT © rayjun