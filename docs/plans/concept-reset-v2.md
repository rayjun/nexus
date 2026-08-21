# Nexus Mobile — Concept Reset & UI Redesign (v2)

Date: 2026-08-20 — DESIGN ONLY, no code yet.
Status: pending user confirmation

## 0. The core reset

The previous v1 refactor made "Agent = local registry entry bound to a session".
That was backwards. The product truth is:

> **A bot IS a Hermes profile. The app is a chat app whose contact list is
> the profile roster of the connected Hermes servers.**

Verified against hermes-agent `tui_gateway`:
- `profiles.list` returns name/display_name/description/model/provider + per-profile
  `last_session` (newest-message preview + time, messaging-app semantics) +
  `ui_meta` (avatar/accent/pinned order, stored server-side so every device
  paints the same roster) — **the home screen data source already exists.**
- `profiles.create(name, description, soul, model, provider, clone_from,
  no_skills, mirror_credentials)` — **creating a bot = one remote call.** No
  server-side development needed.
- `session.resume(profile:, session_id:)` / `session.create(profile:)` /
  `session.status(profile:)` all accept a profile — every chat op targets a
  specific bot.
- `profiles.configure` / `get_asset` / `set_asset` cover bot settings + avatar.

## 1. Revised concepts

| 概念 | 含义 | 实现 |
|------|------|------|
| **Channel** (聊天框) | 首页列表里的一项；一个 bot 的所有对话 | profile + 一个活跃 session |
| **Bot** | 一个 Hermes profile（独立身份/模型/记忆） | `profiles.*` |
| **Server** | 一台 Hermes 主机（可挂多个 bot） | `RelayClient` 多连接 + `ServerStore` |
| **Chat** | 选定 bot 的对话页 | `session.resume/last_session` + `prompt.submit(profile:)` |
| **Session** | bot 的一次对话流（后台概念，不暴露） | session_id（可选 preferred） |

### Where things live
- **Server 配对** → 只在 **Settings**（多 server 列表、增删、re-pair）。首页不出现。
- **Bot 创建** → 首页 `+` → 选 server → `profiles.create`。每个 bot 一个 profile。
- **首页** → `profiles.list` 平铺所有 bot（跨 server），每项 = 头像+名+最新消息预览+时间。server 归属用细标签（不分组，保纯净）。
- **本地状态** → App 只记「每 bot 的 preferred session」（打开哪个对话），其余一切以服务端 `profiles.list` 为准。**删除本地 AgentRegistry/AgentStore 的 agent 概念**（会话 cache 可保留为 timeline 缓存）。

## 2. Architecture (layers)

```
┌────────────────────────────────────────────┐
│ UI (SwiftUI)                                │
│  ChatList (首页: profiles.list roster)      │
│  ChatView  (单 bot 对话: resume+submit)     │
│  CreateBotSheet / BotSettingsView           │
│  SettingsView (servers 管理, 不碰聊天)       │
├────────────────────────────────────────────┤
│ State                                     │
│  ChatStore: roster = profiles.list 缓存     │
│  ServerStore (UserDefaults)  ← 已有 ✓       │
│  KeychainHelper (E2E 密钥)  ← 已有 ✓        │
├────────────────────────────────────────────┤
│ Transport ← 已有 ✓ (不变)                  │
│  RelayClient / ServerConnection /           │
│  PairingView / QRScanner                    │
├────────────────────────────────────────────┤
│ Crypto ← 已有 ✓ (不变)                     │
│  E2ECrypto: X25519+ChaCha+PSK-blend+rekey  │
└────────────────────────────────────────────┘
```

**复用（不动）**：PairingView、QRScannerView、RelayClient、ServerConnection、
E2ECrypto、ServerProfile/ServerStore、NexusStyle、SessionIDExtractor。

**移除/重构**：
- 删除 `AgentStore` / `AgentRegistry` / `NexusAgent` 的"本地 agent 注册表"模型；
  重构为 `ChatStore`：`[Bot]`（来自 profiles.list）+ 每 bot `preferredSessionID`
  + timeline 缓存。
- 删除 `AgentComposeView`（New chat/Import session 模式）→ 换 `CreateBotSheet`
  （profiles.create）。Import 模式的意义消失——所有 bot 都是 profile。
- `AgentChatView` → `ChatView`：以 `profile` 为目标（resume/create/submit 全部
  带 profile 参数），不再面向本地 agent。

## 3. UI design — Grok-style minimal (FINAL, user-approved 2026-08-21)

Design tokens (light + dark, Grok's clean look):
- Flat surfaces, no card borders; rows plain with generous padding.
- Large rounded avatar per bot (initial / `ui_meta` avatar asset).
- Chat list row: avatar · name + one-line preview · HH:mm right. `•••` per row.
- Theme: default **light**, dark toggle. Native SF Symbols.

Screens (user-approved mock: `docs/plans/ui-mock-v2.html`, 8 pages):
1. **ChatListView (home)** — top bar: 🔍 search (LEFT) · `+` new bot · ⚙ settings
   (right). No app wordmark, no status row. Full-bleed bot/channel list,
   flat rows (avatar, name+server tag, preview, time, `•••`). No footer hints.
2. **ChatView** — bot avatar+name+online · timeline bubbles with time ·
   TG-style input bar or T G: `[📎] [Message… 😊] [🔼]` — smiley INSIDE the
   input field (right side); tapping 😊 toggles emoji panel (Emoji/Stickers/
   Files tabs + grid) between input bar and message area; tapping 📎 opens
   attach panel (Photo/File/Camera); `/` prefix pops command suggestion card
   above the input bar (TG style). Panels are part of the chat sheet (input
   bar stays visible), mutually exclusive.
3. **CreateBotSheet** — name (slug, required) · server picker · personality
   (SOUL) · model picker. Calls `profiles.create`.
4. **SettingsView** — Servers entry (chevron, sub: "N connected · pair &
   manage") + independent rows Appearance / Notifications / Privacy &
   Security / About. No section headers, no bots in settings.
5. **ServersView** (settings sub-page) — back chevron + "Servers" title +
   `+` top-RIGHT (pair); server rows with online/offline·Re-pair; no notes.
6. Bot management (rename/avatar/delete) via `•••` / swipe on chat list rows.

## 3a. App architecture (post-v2)

```
UI (SwiftUI)        ChatListView / ChatView(emoji/attach/command panels)
                    CreateBotSheet / SettingsView / ServersView / PairingView
State               ChatStore (roster from profiles.list + preferred session
                    per bot, timeline cache) · ServerStore (unchanged)
Transport (keep)    RelayClient / ServerConnection / Pairing / QRScanner
Crypto (keep)       E2ECrypto (unchanged)
Models              Bot (profile-shaped) · TimelineItem/SessionSummary ·
                    SessionIDExtractor (keep)
Remove              AgentRegistry / NexusAgent register-model / AgentHomeView /
                    AgentChatView / AgentViews compose-import mode
```

## 4. Data flows

- **Home load**: for each server → `profiles.list(include_sessions=true)` →
  merge into roster; if server offline → show cached roster, dim bots.
- **Open chat**: `ChatView` calls `session.resume(profile: name, session_id:
  preferred ?? last_session.id)` → stream history → render; send:
  `prompt.submit(profile: name, session_id: resolved)`. Bind resolved live sid
  back as the bot's `preferredSessionID`.
- **Create bot**: `profiles.create(name:..., description:..., soul:...,
  model:..., provider:...)` → refresh roster.
- **Bot rename/avatar**: `profiles.configure` / `set_asset` → refresh.

## 5. Out of scope for v2
- Streaming `message.delta` (still reload-after-submit).
- Cross-bot messaging (needs server scoped-session model).
- Approvals pane (badge/toast only).
- Multi-device presence.

## 6. Migration
- Old local `nexus_agents_v1` / `nexus_agent_chats_v1` → migrate: agents whose
  `boundSessionID` exists were real sessions → keep as bot entries keyed by
  profile guess (best-effort drop if name can't map); safer: ignore local
  agents, home is driven by `profiles.list` server truth.
- Keep `nexus_agent_chats_v1` as timeline cache keyed by profile (not agent).

## 7. Waiting on confirmation
1. Flat roster across servers w/ server tag (recommended) vs grouped sections?
2. Import-session mode removed entirely in favor of create-only (recommended)?
3. Timeline cache keyed by profile, cleared per bot delete.
4. HTML mock for the 4 screens before SwiftUI? (recommended yes)
