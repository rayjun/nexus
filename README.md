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

## 连接配置

Nexus 通过 WebSocket + JSON-RPC 直连 Hermes Dashboard，不需要独立后端。下面按场景说明完整配置流程。

### 为什么连 Dashboard 而不是 API Server

Hermes 有两个独立服务：

| | Hermes API Server (8642) | Hermes Dashboard (8080) |
|---|---|---|
| 协议 | HTTP REST，OpenAI 兼容 | WebSocket + JSON-RPC |
| 认证 | `API_SERVER_KEY` (Bearer) | `HERMES_DASHBOARD_SESSION_TOKEN` (?token=) |
| 面向 | 第三方 LLM 前端 (Open WebUI, LibreChat…) | Hermes 原生客户端 (Desktop, Nexus) |
| 实时事件 | 无（纯请求-响应） | `gateway.ready`、`session.info`、`message.delta` 等推送 |
| 可用 RPC | `/v1/chat/completions`、`/v1/responses` 等 | `session.list`、`session.resume`、`prompt.submit`、`cron.manage`、`approval.respond` 等 |

Nexus 是 Hermes 原生移动端，需要实时事件推送、流式输出、cron 管理和审批等功能，这些只有 Dashboard 的 WebSocket 提供。API Server 是给 OpenAI 兼容前端用的，不支持这些能力。

### 两个 Key 的区别

- **`API_SERVER_KEY`**：用于 API Server 8642 的 REST Bearer 认证，长期有效，写在 `config.yaml` 中。
- **`HERMES_DASHBOARD_SESSION_TOKEN`**：用于 Dashboard 8080 的 WebSocket `?token=` 认证，进程级凭据，Dashboard 退出即失效（可通过环境变量固定）。

Nexus 使用的是 **`HERMES_DASHBOARD_SESSION_TOKEN`**，不是 `API_SERVER_KEY`。两者是完全独立的认证体系，互不通用。

### 场景一：本机模拟器（最简单）

模拟器与本机 Dashboard 在同一台机器上，直接走 loopback HTTP/WS，不需要 Caddy 和 TLS。

#### 1. 生成 Dashboard Token

```bash
TOKEN=$(openssl rand -hex 16)
echo "HERMES_DASHBOARD_SESSION_TOKEN=$TOKEN" >> ~/.hermes/.env
echo "Your token: $TOKEN"
```

#### 2. 启动 Dashboard

```bash
export HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN"
hermes dashboard --port 8080 --host 127.0.0.1 --insecure
```

- `--host 127.0.0.1`：绑定 loopback，不需要外部访问
- `--insecure`：使用 token 认证，不启用 OAuth gate

验证：

```bash
curl -s http://127.0.0.1:8080/api/status | python3 -m json.tool
```

应返回 `"gateway_state": "running"` 和 `"overall": "ok"`。

#### 3. 在 Nexus 中连接

DEBUG 模式下 App 自动填充 `http://127.0.0.1:8080` 和 token，会自动连接。手动操作：

- **GATEWAY**：`http://127.0.0.1:8080`
- **API KEY**：你生成的 token 值
- 点击 Connect

App 会自动把 `http://` 转为 `ws://`，并追加 `/api/ws?token=YOUR_TOKEN`。

### 场景二：远程真机通过 Caddy WSS

iOS 26+ 要求所有网络连接走 TLS。远程真机需要 Caddy 做 HTTPS/WSS 反向代理。

```
iPhone (wss://) ←→ Caddy (TLS :8444) ←→ Hermes Dashboard (HTTP :8080)
```

#### 1. 在服务器上生成 Token 并启动 Dashboard

```bash
TOKEN=$(openssl rand -hex 16)
echo "HERMES_DASHBOARD_SESSION_TOKEN=$TOKEN" >> ~/.hermes/.env
export HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN"
hermes dashboard --port 8080 --host 127.0.0.1 --insecure
```

Dashboard 绑定 loopback，由 Caddy 负责对外 TLS。

#### 2. 安装并配置 Caddy

```bash
# Ubuntu/Debian
sudo apt install caddy

# macOS
brew install caddy
```

编辑 Caddyfile（替换 IP 为你的服务器地址）：

```
https://YOUR_SERVER_IP:8444 {
    reverse_proxy 127.0.0.1:8080
    tls internal
}
```

- `tls internal`：Caddy 自动生成自签名证书
- WebSocket 在反向代理中自动透传

启动 Caddy：

```bash
sudo systemctl restart caddy
# 或手动测试
caddy run --config /etc/caddy/Caddyfile
```

验证代理：

```bash
curl -sk https://YOUR_SERVER_IP:8444/api/status | python3 -m json.tool
```

#### 3. 在 Nexus 中连接

- **GATEWAY**：`https://YOUR_SERVER_IP:8444`
- **API KEY**：你生成的 `HERMES_DASHBOARD_SESSION_TOKEN` 值
- 点击 Connect

App 自动处理：
1. `https://` → `wss://`
2. 追加 `/api/ws?token=YOUR_TOKEN`
3. Caddy 终止 TLS，代理到 `ws://127.0.0.1:8080/api/ws?token=YOUR_TOKEN`
4. Dashboard 验证 token，接受连接
5. App 接受自签名证书（通过 `InsecureURLSessionDelegate`）

### 场景三：Tailscale 直连（推荐，最简单）

如果你的设备和服务器都在 Tailscale 网络中，可以直接走 Tailscale 内网，不需要 Caddy。

#### 1. 启动 Dashboard 绑定 Tailscale IP

```bash
export HERMES_DASHBOARD_SESSION_TOKEN="$TOKEN"
hermes dashboard --port 8080 --host 0.0.0.0 --insecure
```

- `--host 0.0.0.0`：允许 Tailscale 接口访问
- Tailscale 网络本身即认证边界，不需要额外 TLS

#### 2. 在 Nexus 中连接

- **GATEWAY**：`http://YOUR_TAILSCALE_IP:8080`
- **API KEY**：你生成的 token 值
- 点击 Connect

> **注意**：Tailscale 内网走 HTTP/WS 即可，ATS 已允许 arbitrary loads。Tailscale 本身提供加密隧道，不需要应用层 TLS。但 iOS ATS 对非 localhost 的 HTTP 连接有限制，如果连接失败，仍需 Caddy 提供 HTTPS。

### 认证原理

Dashboard WebSocket 认证逻辑（`web_server.py` `_ws_auth_reason`）：

1. **Loopback / `--insecure` 模式**（场景一、三）：
   - 客户端发送 `?token=<HERMES_DASHBOARD_SESSION_TOKEN>`
   - 服务端用 `hmac.compare_digest` 常量时间比较
   - 匹配则接受，否则关闭连接（code 4401）

2. **Gated 模式**（公网绑定，不带 `--insecure`）：
   - `?token=` 路径被直接拒绝
   - 改用单次 ticket（30 秒过期）或 internal credential
   - **Nexus 不支持此模式**，请确保 Dashboard 使用 `--insecure` 或绑定 loopback + Caddy

3. **为什么不直接用 `API_SERVER_KEY`**：
   - Dashboard 不查 `API_SERVER_KEY`，两者是完全独立的认证体系
   - `API_SERVER_KEY` 是长期凭据，泄露后果更严重
   - Dashboard token 是进程级凭据，重启自动轮换，权限范围更小

### 持久化运行（可选）

生产环境推荐用 systemd 持久化 Dashboard：

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

### 验证清单

配置完成后按顺序检查：

1. **Dashboard 运行**：`curl -s http://127.0.0.1:8080/api/status` → `"gateway_state": "running"`
2. **Caddy 代理**（远程场景）：`curl -sk https://YOUR_IP:8444/api/status` → 同上
3. **Token 正确**：App 中 API KEY 值 = `~/.hermes/.env` 中的 `HERMES_DASHBOARD_SESSION_TOKEN`
4. **WebSocket 连通**：连接成功后 App 日志显示 `gateway.ready` 和 `session.list` RPC 成功
5. **数据加载**：Sessions 页面显示会话列表，Agents 页面显示 Agent 列表

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

- 确认 Dashboard 在运行：`curl -s http://127.0.0.1:8080/api/status`
- 确认 Caddy 在运行（远程场景）：`sudo systemctl status caddy`
- 确认 Tailscale 连通：`tailscale status`
- 确认 App 中 API KEY = `~/.hermes/.env` 中的 `HERMES_DASHBOARD_SESSION_TOKEN`

### "Connection timed out"

- 检查防火墙是否放行 8444 端口
- 确认 Caddy 在监听：`ss -tlnp | grep 8444`
- 从另一台设备测试：`curl -sk https://YOUR_IP:8444/api/status`

### "WebSocket immediately closes (code 4401)"

- 4401 = 认证失败
- 确认 token 值完全匹配，没有多余空格或换行
- 确认 Dashboard 以 `--insecure` 启动（gated 模式下 `?token=` 会被拒绝）
- 检查 `~/.hermes/.env` 中的 `HERMES_DASHBOARD_SESSION_TOKEN` 是否与启动时一致

### "code = 4001 session not found"

- 4001 = 历史 session 不可直接访问
- App 已通过 `session.resume` 处理，如果仍出现请确认 Hermes Agent 版本支持 `session.resume` RPC

### "Invalid code signature"

安装到真机后信任开发者证书：
**Settings → General → VPN & Device Management → Trust Developer Certificate**

### WebSocket connection drops

App 内置自动重连和 30 秒 ping keepalive。如果持续断开：
- 检查 Dashboard 稳定性：`journalctl -u hermes-dashboard -f`
- 检查 Caddy 日志：`journalctl -u caddy -f`

## Privacy Policy

Nexus does not collect, transmit, or store any personal data. All communication occurs directly between the app and your self-hosted Hermes Gateway via encrypted WebSocket (WSS). No analytics, no telemetry, no third-party SDKs. API keys are stored locally in iOS Keychain and never leave the device.

## Tech Stack

- **iOS**: SwiftUI, URLSession WebSocket, Keychain (Security framework)
- **Backend**: Hermes Agent dashboard server (WebSocket JSON-RPC)
- **TLS**: Caddy reverse proxy with self-signed certificates
- **LLM**: Hermes Agent → any OpenAI-compatible model

## License

MIT © rayjun