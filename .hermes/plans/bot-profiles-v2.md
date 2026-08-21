# Plan: Concept Reset v2 — Bot = Hermes Profile (iOS)

Date: 2026-08-21
Spec: `docs/plans/concept-reset-v2.md` (final, user-approved mock
`docs/plans/ui-mock-v2.html`)
Type: complex (cross-module UI rewrite + server allowlist change)
Status: draft → pending plan review

## 0. Verified contract (source-cited, 2026-08-20)

- `profiles.list(include_sessions=true)` returns per-profile: name, path,
  is_default, model, provider, description, display_name, skill_count,
  `last_session` (newest msg preview + time, msg-app semantics),
  optional `preferred_session` (via preferred_session_ids map), `ui_meta`
  (avatar/accent/order, server-side). methods_profiles.py:22-...
- `profiles.create(name, description, soul, model, provider, clone_from,
  no_skills, mirror_credentials)` — one remote call creates a bot.
  methods_profiles.py:251-...
- `profiles.configure` / `profiles.get_asset` / `profiles.set_asset` (bot
  settings + avatar).
- `session.create/resume/status` all accept `profile` param — chat ops target
  a specific bot. methods_session.py:42/324/2524
- `prompt.submit` returns `{"status":"streaming"}` only — MUST session.create
  for a new thread and bind the live sid. methods_prompt.py:268/809
- **GAP**: relay_agent.py:389-394 allowlist LACKS `profiles.*` — must add
  `profiles.list`, `profiles.create`, `profiles.describe`, `profiles.configure`
  for the app to roster/create bots. (Do NOT add set_asset/get_asset in v2 —
  avatar upload deferred.)

## 1. Goals (v2 Defined)

- Home = chat list driven by `profiles.list` (server truth) across all paired
  servers, flat, no wordmark/status row; search (top-left), `+` new bot, ⚙
  settings.
- ChatView per bot: TG input bar `[📎][Message… 😊][🔼]` with smiley INSIDE
  input; 😊 toggles emoji panel (Emoji/Stickers/Files), 📎 toggles attach
  panel (Photo/File/Camera), `/` prefix → command suggestion card; panels
  keep input bar visible and are mutually exclusive.
- CreateBotSheet → `profiles.create`; Settings (general, no sections) with
  Servers entry → ServersView (list + re-pair + `+` pair, no notes).
- Bot manage (rename/avatar/delete) via `•••` menu on chat list rows.
- Remove AgentRegistry/NexusAgent registry model; replace with server-driven
  roster. Import-session mode removed (all bots are profiles now).
- Light theme default + dark toggle.

## 2. Non-goals (v2)
- Avatar upload/asset endpoints (set_asset/get_asset) — UI hides until later.
- Streaming message.delta; approval pane; cross-bot messaging; multi-device.

## 3. Architecture changes

### 3.1 Server side (relay) — MUST ship with iOS
- `relay/relay_agent.py` allowlist += `profiles.list`, `profiles.create`,
  `profiles.describe`, `profiles.configure` (line ~389).

### 3.2 New/changed iOS files
| File | Action | Responsibility |
|---|---|---|
| `Bot.swift` | new | `Bot` model (profile shape: name/displayName/desc/model/provider/serverID + preferredSessionID/lastSession cache), `BotStatus` |
| `ChatStore.swift` | new | `ChatStore: ObservableObject` — roster refresh via per-server `profiles.list`, bot CRUD (create/rename/delete), per-bot `chats` timeline cache, preferred session map (UserDefaults) |
| `ChatListView.swift` | new | Home: search bar, roster list, `•••` context menu (edit/delete), `+` → CreateBotSheet, ⚙ → Settings |
| `ChatView.swift` | new | Chat + TG input bar + emoji/attach/command panels; session create/resume/submit with `profile:`; interrupt |
| `CreateBotSheet.swift` | new | Name/slug, server picker, SOUL, model picker → profiles.create |
| `SettingsView.swift` | new | Servers entry + Appearance/Notifications/Privacy/About rows (stubs) |
| `ServersView.swift` | new | Server list, re-pair, `+` pair (reuse PairingView sheet) |
| `SessionIDExtractor.swift` | keep | reused by ChatView |
| `AgentXxx.swift` (4 files) | delete | AgentHome/AgentChat/AgentViews/AgentStore registry model (NexusAgent stays only if still used → delete) |
| `NexusApp.swift` | edit | root: servers.empty→PairingView else ChatListView; ShowPairingView sheet |
| `project.pbxproj` | edit | register new files, unregister deleted |
| `NexusStyle.swift` | edit | light-default palette + dark scheme |

### 3.3 Data flow
- Roster: for each server (in order) `profiles.list(include_sessions: true)` →
  merge; offline servers show cached roster dimmed.
- Open chat: `session.resume(profile:, session_id: preferred ?? last)` →
  timeline → send `prompt.submit(profile:, session_id: resolved)`; bind live
  sid as preferred session.
- Create bot: `profiles.create(...)` → refresh roster.
- Command card: static `/` suggestions (status/help/agents/model) → send as
  prompt text; commands are app-side affordances (server slash semantics later).

## 4. Tasks

- T1 relay allowlist + profiles methods (1 commit)
- T2 Bot.swift + ChatStore.swift + unit contract checks (contract-tests
  extended: profiles.list shape, preferred_session)
- T3 pbxproj registration + deletion cleanup; build green
- T4 ChatListView (roster, search, •••, empty states) + NexusApp root switch
- T5 ChatView: timeline + TG input bar + emoji/attach/command panels
- T6 CreateBotSheet + SettingsView + ServersView
- T7 Theme (light default + dark)
- T8 build + validator, full smoke (simulator with local stack — needs venv
  rebuild + dashboard): roster → create bot → open chat → send → interrupt

## 5. Verification
- Build green at each step; contract-tests amended for profiles shapes and
  run 6/6; simulator smoke per T8; review via subagent (Step 6) before commit.

## 6. Out of scope
Streaming, approvals pane, cross-bot, avatar assets, xcodegen/XCTest (carryover).