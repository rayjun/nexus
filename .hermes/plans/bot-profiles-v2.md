# Plan: Concept Reset v2 — Bot = Hermes Profile (iOS)

Date: 2026-08-21
Spec: `docs/plans/concept-reset-v2.md` (final, user-approved mock
`docs/plans/ui-mock-v2.html`)
Type: complex (cross-module UI rewrite + server allowlist change)
Status: rev3 — post re-review (blocking cleared; 2 new edits applied)

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
  `profiles.list`, `profiles.create`, `profiles.configure` for roster/create/
  rename. `profiles.describe` OMITTED (least privilege, no UI consumer);
  `set_asset/get_asset` NOT added (avatar deferred). Avatar = goal scope cut:
  ••• menu is rename/delete only.
- **DELETE PATH (T1 verify)**: check hermes-agent methods_profiles.py for
  `profiles.delete`/`profiles.remove`. If present → allowlist + implement
  server delete + local prune. If absent → v2 delete = LOCAL TOMBSTONE
  (profile persists server-side; state this in UI copy) — decided at T1.
- **last_session shape (T2 pin)**: {id, title, preview, last_active/message_count}
  per methods_profiles.py:160-162; `last_session.id` is the resume target.
- **Roster RPC**: RelayClient gains `call(serverID:method:params:)` thin
  wrapper (per-server routing, no active-server flip inside roster refresh).

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
- Bot manage via `•••` menu: rename (profiles.configure) + delete
  (server delete if exists, else local tombstone). Avatar deferred (no assets).
- Remove AgentRegistry/NexusAgent registry model; replace with server-driven
  roster. Import-session mode removed (all bots are profiles now).
- Light theme default + dark toggle.

## 2. Non-goals (v2)
- Avatar upload/asset endpoints (set_asset/get_asset) — UI hides until later.
- Streaming message.delta; approval pane; cross-bot messaging; multi-device.

## 3. Architecture changes

### 3.1 Server side (relay) — MUST ship with iOS
- `relay/relay_agent.py` allowlist += `profiles.list`, `profiles.create`,
  `profiles.configure` (line ~389). `profiles.describe` OMITTED (least
  privilege). `profiles.delete` added ONLY if T1 verifies it exists.

### 3.2 New/changed iOS files
| File | Action | Responsibility |
|---|---|---|
| `Bot.swift` | new | `Bot` model (profile shape: name/displayName/desc/model/provider/serverID + preferredSessionID/lastSession cache), `BotStatus` |
| `ChatStore.swift` | new | `ChatStore: ObservableObject` — roster merge (per-server `profiles.list` via `RelayClient.call(serverID:)`), refresh on RelayPaired/reconnect, CRUD, prune on server removal; merge FILTERS local tombstones (server truth re-pull must not resurrect a tombstoned profile) | 
| `BotStore.swift` | new | persistence layer (mirrors v1 AgentStore split): last-good roster cache, per-bot timeline cache, preferred-session map — UserDefaults keys `nexus_roster_v2`/`nexus_chats_v2`/`nexus_preferred_v2`, keyed `serverID:profileName`; legacy `nexus_agents_v1`/`nexus_agent_chats_v1` abandoned (old sessions resurface via last_session) |
| `ChatInputBar.swift` | new | TG input bar: `[📎][Message… 😊][🔼]`, 😊 inside field; single `@State panel: .none/.emoji/.attach`; keyboard-dismiss rule |
| `EmojiPanel.swift` | new | Emoji/Stickers/Files tabs + grid; insert into input |
| `AttachPanel.swift` | new | Photo/File/Camera (stubs — v2: attach as text note) |
| `CommandSuggestCard.swift` | new | `/` prefix → suggestion card (/status /help /agents /model) |
| `ChatListView.swift` | new | Home: search bar, roster list, `•••` context menu (edit/delete), `+` → CreateBotSheet, ⚙ → Settings |
| `ChatView.swift` | new | timeline + ChatInputBar orchestration, session resolve/create/resume/submit with `profile:`, interrupt; panels are separate files |
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
- Open chat resolution (T5 acceptance): LOCAL `nexus_preferred_v2` map is the
  authoritative `preferred` source (server-side preferred_session_ids read-only
  for now; stale preferred → fall through to last?.id → create-new). Sequence:
  `session.resume(profile: name, session_id: preferred ?? last?.id)`. NO id at
  all (fresh bot) → `session.create(profile: name, title:)` → bind live sid
  (SessionIDExtractor) as preferred. Resume/history errors (stale id) → same
  create-new fallback.
  Send: `prompt.submit(profile:, session_id: resolved)` (streaming-only ack —
  bind only from create/resume responses).
- Create bot: `profiles.create(...)` → refresh roster.
- Command card: static `/` suggestions (status/help/agents/model) → send as
  prompt text; commands are app-side affordances (server slash semantics later).

## 4. Tasks

- T1 relay allowlist += profiles.list/create/configure (+delete if exists);
  live relay→dashboard profiles.list round-trip check
- T2 Bot.swift (id = serverID:profileName) + BotStore + ChatStore (+ per-server
  `RelayClient.call(serverID:)`); contract-tests extended (profiles.list shape,
  last_session, create round-trip, configure rename fields, slug validation)
- T3 ChatListView + NexusApp root switch to ChatListView (Agent* still
  compiled; register files as created). `+`/⚙ wire to INLINE PLACEHOLDER
  sheets (empty stubs) so T3 is build-green; real CreateBotSheet/SettingsView
  replace them in T4 — build green
- T4 CreateBotSheet (slug validation, NO mirror_credentials) + SettingsView +
  ServersView; register as created — build green
- T5a ChatView: session resolution flow + timeline + send/interrupt — green
- T5b EmojiPanel + ChatInputBar 😊 toggle (panel enum) — green
- T5c AttachPanel + CommandSuggestCard — green
- T6 CLEANUP (single step): delete Agent* 5 files + NexusAgent refs +
  pbxproj entries (20 in 4 sections); prune legacy keys — build green
- T7 Theme: light default via `.preferredColorScheme(.light)` at root + dark
  toggle
- T8 verification: contract-tests.swift (named validator) + build + simulator
  smoke (needs venv rebuild + dashboard exposing profiles.*); tasks.json +
  STATUS.md maintenance (AGENTS.md steps 2/8)

## 5. Verification
- Build green at each step; contract-tests amended for profiles shapes and
  run 6/6; simulator smoke per T8; review via subagent (Step 6) before commit.

## 6. Out of scope
Streaming, approvals pane, cross-bot, avatar assets, xcodegen/XCTest (carryover).