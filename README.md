# Nexus

A native iOS app for managing AI agents powered by Hermes Agent. Create persistent agents, chat with them via Hermes LLM, manage agent servers, and monitor sessions — all from your phone.

## Features

- **Agent Server Management** — Add, edit, and remove Hermes agent servers with custom names and URLs
- **Persistent Agents** — Create AI agents with custom icons, names, and descriptions. Each agent maintains conversation context via Hermes sessions
- **Real LLM Chat** — Messages route through Hermes API server (OpenAI-compatible endpoint), with session continuity via `X-Hermes-Session-Id`
- **Session Timeline** — View Hermes session execution timelines with tool calls, thinking blocks, and results
- **Inbox** — Active tasks (running Hermes sessions) and pending approvals
- **Cron Jobs** — View scheduled tasks from `~/.hermes/cron/jobs.json`
- **Code Highlighting** — Syntax highlighting for code blocks in chat (Swift, Python, Rust, Go, C/C++, Bash)
- **Secure Storage** — Device tokens stored in iOS Keychain
- **Auto-Reconnect** — Automatically re-pairs with gateway on token expiration

## Requirements

- iOS 16.0+
- Xcode 15+ or Swift 5.9+
- Hermes Agent with API server platform enabled (`hermes config set gateway.platforms.api_server.enabled true`)
- `API_SERVER_KEY` set in `~/.hermes/.env`

## Installation

### Build & Run

```bash
cd apps/iosApp
open iosApp.xcodeproj
# In Xcode: select iosApp scheme, choose simulator, Run
```

### Start the Backend Gateway

```bash
# Install dependencies
pip install fastapi uvicorn httpx pydantic pyyaml

# Start mobile gateway
HERMES_MOBILE_USE_STATE_DB=1 \
  python -m uvicorn backend_plugin.hermes_mobile.server:app --host 0.0.0.0 --port 8765
```

### Enable Hermes API Server

```bash
hermes config set gateway.platforms.api_server.enabled true
echo "API_SERVER_KEY=your-secret-key" >> ~/.hermes/.env
hermes gateway restart
```

### Run Tests

```bash
python -m pytest tests/ -q
```

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
- **Mobile Gateway** (FastAPI): Pairing, device auth, CRUD for agents/sessions/cron/approvals
- **Hermes API Server**: OpenAI-compatible `/v1/chat/completions` endpoint with session continuity

## Tech Stack

- **iOS**: SwiftUI, URLSession, Keychain (Security framework)
- **Backend**: Python, FastAPI, SQLite (state.db), httpx
- **LLM**: Hermes API server → any OpenAI-compatible model

## License

MIT © rayjun