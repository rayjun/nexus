# Plan: Agent-Centric V1 — Implementation

Date: 2026-08-18
Spec: `docs/plans/agent-centric-refactor.md` (rev 2)
Type: complex (cross-module, UI pivot, persistence)
Status: WARN → patched (Agent.id stable localID, TimelineItem Codable, no re-key, approval parsing fixed, stale nav guard, lostKeys observer)

## 0. Context

Previous design (rev 2, FIX-AND-GO) established:
- Verified facts: `session.create/resume` + `prompt.submit(session_id:"new")` give a real "one persistent thread per agent"; `agents.list` is UNVERIFIED (real gateway returns `processes`), `delegate_task` is isolated-worker delegation, not peer messaging.
- Decision: Agent = `<serverID>:<sessionID>` bound to a persisted session; agents.list only as optional enrichment.

This plan turns that design into the first shippable slice.

## 1. Goals (v1 Definition of Done)

- Cold launch with 0 servers → onboarding message + CTA to pair a server (REUSES existing PairingView flow). No blank screen, no dead spinner.
- Home screen is an **agent list** (not a session list), grouped by server, with a prominent "Add Agent" entry. Each agent card: name/icon, last message preview (from cache), status dot, entry to chat.
- "Add Agent" = pick a server (already paired) → import by choosing an existing session (via `session.list` - verified shape) OR start a brand-new chat (session created on first `prompt.submit`). A manual-create stub is shown but disabled with "available in v2".
- Tapping an agent opens **AgentChat**: one thread, owns `boundSessionID`, supports send / interrupt / timeline render, reuses the current markdown+tool-call views. No new wire protocol.
- Agent detail: edit name/icon/description locally, delete (registry-only, server session untouched).
- Offline / lost-key servers: their agents stay visible (dimmed + badge), with a "re-pair" entry point on Home.
- No removal of the old dashboard/tabs in this slice - the new home coexists behind a feature flag/root switch that can be flipped atomically in a follow-up commit (this keeps the PR reviewable and the build green).

## 2. Non-goals (v1)

- `delegate_task` → worker affordance (defer to v1.1 once chat is solid).
- `agents.create/update/delete` on the relay allowlist.
- Cron / approvals / artifacts UI migration.
- True cross-agent messaging / context-bridging thread (v2).
- Deleting the old Sessions tab - keep it behind the old path until the new home is proven.

## 3. Architecture

### 3.1 New files (each its own file; no ContentView growth)

| File | Responsibility |
|------|---------------|
| `apps/iosApp/iosApp/Agent.swift` | `Agent` model, `AgentStatus`, persistence DTO |
| `apps/iosApp/iosApp/AgentStore.swift` | Registry + chat-cache persistence (UserDefaults file mirroring `ServerStore`), seed from `session.list` on first run |
| `apps/iosApp/iosApp/AgentHomeView.swift` | Home list, empty states, offline badges, approvals badge entry, navigation to chat/compose/detail |
| `apps/iosApp/iosApp/AgentChatView.swift` | Single-thread chat (reuses `MobileGatewayClient.SessionTimeline` rendering + interrupt) |
| `apps/iosApp/iosApp/AgentComposeView.swift` | Add: server picker + session picker / "new chat" |
| `apps/iosApp/iosApp/AgentDetailView.swift` | Edit/delete (registry-only) |

Shared helpers stay where they are: `RelayClient`, `ServerConnection`, `ServerStore`, `E2ECrypto`, `MobileGatewayClient` decoders, `KeychainHelper`.

### 3.2 Data model (authoritative)

```swift
struct Agent: Identifiable, Codable, Equatable, Hashable {
  var id: String               // "<serverID>:<boundSessionID>" or "<serverID>:new:<UUID>" before first message
  var serverID: String         // FK → ServerProfile.id
  var boundSessionID: String   // "" until first prompt materializes it (via resume/next id)
  var name: String
  var icon: String             // SF Symbol name, default "sparkles"
  var description: String
  var status: AgentStatus      // .ready | .offline | .lostKeys | .unpaired
  var lastError: String?
  var createdAt: Date
  var updatedAt: Date
  var lastMessageAt: Date?
  var lastPreview: String?     // cached last-message preview for the card
}

enum AgentStatus: String, Codable { case ready, offline, lostKeys, unpaired }
```

Notes:
- `id` is server-qualified and stable. Before the first prompt the suffix is `new:<uuid>` so the card already exists locally; after `prompt.submit` returns the real session id, the agent is re-keyed (old id removed, new `<server:session>` id inserted).
- `boundSessionID == ""` means "no server thread yet".
- `AgentStore` owns `agents: [Agent]` and a per-agent `chatCache: [String: [TimelineItem]]` (keyed by agent.id), both Codable and persisted to UserDefaults under `nexus_agents_v1` / `nexus_agent_chats_v1`.
- Seeding: if persisted agents is empty and `session.list` returns recent sessions, offer them as import candidates (do not auto-create agents - user must confirm).

### 3.3 Navigation

```
NexusApp.root:
  if relay.servers.isEmpty        → PairingView (unchanged)
  else if AgentStore.agents.isEmpty and !hasCompletedSeedPrompt
                                  → AgentHomeView (empty state with "Pair a server / Import from sessions")
  else                           → AgentHomeView
      ├─ tap agent        → AgentChatView(agent)
      │                      └─ detail button → AgentDetailView
      └─ "+ Add Agent"    → AgentComposeView
                              └─ on confirm → AgentHomeView (new card)

Settings / Add Server remain via the same PairingView entry points.
```

Build flag approach: introduce `AgentHomeView` and switch `NexusApp` to it as the primary branch (old `ContentView` remains buildable but is no longer the root). This satisfies the "one atomic flip" intent without deleting 3000 lines in the same PR as new screens - the deletion PR follows after verification.

### 3.4 Chat ownership

- `AgentChatView` owns a `boundSessionID` (String). On `onAppear` it calls `session.history` / `session.resume` equivalently to the current timeline path - reusing the existing `relay.call` routing (activeServerID must match `agent.serverID`; the view sets `relay.setActive(serverID: agent.serverID)` on appear if needed).
- Sending: if `boundSessionID.isEmpty`, send `prompt.submit(session_id:"new", text: input)`; on success, update the agent's `boundSessionID` + `id` + `name` (from returned session title) via `AgentStore`. Otherwise `prompt.submit(session_id: boundSessionID, ...)`. Interrupt stays `session.interrupt`.
- Streaming: reuse the existing `message.delta` bridge in `ServerConnection` → publish to `AgentChatView` via a Combine publisher on `AgentStore`; not a new wire path.

## 4. Detailed tasks

| # | File(s) | Description | Verifies |
|---|---------|-------------|----------|
| T1 | `Agent.swift` | Define `Agent` + `AgentStatus` + CodingKeys + Equatable/Hashable + `displayName`/`stableID` helpers. | Unit decodes round-trip |
| T2 | `AgentStore.swift` | `load()`/`save()` (UserDefaults), `upsert`, `remove(id:)`, `updateStatus(for serverID:)`, chat-cache CRUD, `seedCandidates(from sessions:)` helper. Mirror the `ServerStore` pattern (including `CodingKeys` that exclude transient state). | Persisted JSON round-trip, removal leaves other agents intact |
| T3 | `AgentHomeView.swift` | List grouped by server (`Section` per server), agent card (icon+name+preview+time+status dot), empty states (no servers vs no agents vs offline server), approvals badge (reuse `approvalList` count from a lightweight `loadApprovalsViaWS()` call), pull-to-refresh (reload sessions for import candidates). Navigation: tap→chat, +→compose, gear→settings, add-server→PairingView. | Visual QA on simulator |
| T4 | `AgentChatView.swift` | Header (agent name/icon + status), message list (reuse the current timeline cell rendering - extract a shared `TimelineRow` if needed to avoid duplicating 500 lines), composer (TextField + send), interrupt button (when active), delta streaming hook. On appear: ensure active server, load history for `boundSessionID`. On send of a `new` agent: re-key. | Send on a new agent creates a session; send on bound agent reuses thread |
| T5 | `AgentComposeView.swift` | Form: name/icon/description, server picker (from `relay.servers`), mode picker: "New chat" vs "Import existing session". Import picker: loads `session.list` and shows recent sessions to bind. Validation: name non-empty, server selected, for import a session selected. Confirm → `AgentStore.upsert`. | Create from new chat and from import both produce a card |
| T6 | `AgentDetailView.swift` | Edit fields, status display, lastError, delete (with confirmation, registry-only), re-pair CTA when `lostKeys`. | Delete removes card but not server session |
| T7 | `NexusApp.swift` | Flip root to `AgentHomeView` when servers exist. Keep `PairingView` for the empty-servers branch. Remove the `ContentView` root import from this path (ContentView stays in the target but is no longer presented). | Cold launch: empty→pairing; with servers and 0 agents→home empty; with agents→list |
| T8 | `project.pbxproj` | Register the 6 new Swift files in the Xcode project (PBXBuildFile / PBXFileReference). | `xcodebuild` succeeds |
| T9 | Server/relay sync | `AgentStore.updateStatus(for:)` reacts to `RelayClient` server isOnline/lost-key changes (observe `relay.objectWillChange` or explicit call from `ContentView` leftover). No relay allowlist change in v1. | Removing a server dims its agents; re-pair restores them |

Dependency order: T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9. T8 can run any time after T1; T9 is last polish.

## 5. Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| `id` re-key on first message breaks NavigationStack identity | The chat view holds the agent by `serverID:sessionID` and re-keys by replacing the list entry; navigation uses the agent's current id - verify no stale `Identifiable` cache. Alternative: keep a stable `localID` and store `boundSessionID` separately, but the spec says composite id. Chose re-key for spec fidelity; verify with a tap after first send. |
| Tapping fast "Add Agent" twice | `AgentComposeView` confirm button is disabled while `isSaving` (mirrors PairingView fix). |
| No server / session to import leaves Add disabled forever | Empty state offers "Pair a server" (PairingView) before any import; manual-create stub is visible but labeled v2 so the user understands the path. |
| ContentView deletion pressure | Not in v1 - ContentView stays buildable; deletion is a separate PR after v1 verification. |
| Persistence key collision with ServerStore | New keys: `nexus_agents_v1`, `nexus_agent_chats_v1` - never reuse `nexus_servers_v1`. |

## 6. Verification

- Build: `xcodebuild -project apps/iosApp/iosApp.xcodeproj -scheme iosApp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -derivedDataPath /tmp/nexus-derived CODE_SIGNING_ALLOWED=NO build` must pass after T8.
- Manual QA (simulator):
  1. Fresh install → pairing screen → pair → Home shows "No agents yet — Add Agent".
  2. Add Agent → New chat → send a message → card appears with preview; tap it → thread shows history; send again → same thread grows.
  3. Add Agent → Import session → pick a recent session → chat shows its history.
  4. Edit agent, delete agent (registry-only), pull-to-refresh.
  5. Remove a server (from settings) → its agents dim/offline; re-pair → they restore.
- Unit sanity: `AgentStore` round-trip (encode→decode) preserves agents and chat cache.

## 6a. Contract evidence (verified against hermes-agent tui_gateway, 2026-08-20)

Empirical, source-cited — the send() flow was FIXED against these facts:

- `prompt.submit` returns `{"status":"streaming"}` only (methods_prompt.py:268/809). It does NOT return a session_id.
- `_sess_nowait` resolves `params.session_id` ONLY against live `_sessions` (server.py:2518-2521); `session_id:"new"` → ERR 4001 `session not found`. **Must session.create first.**
- `session.create` returns `{session_id: <8-hex live sid>, stored_session_id: <persisted key>}` (methods_session.py:14/128). send()/history/resume/interrupt take the live sid.
- `session.list` returns `id` = persisted session key (methods_session.py:204-214).
- relay allowlist (relay_agent.py:389-395) already includes `session.create`.

## 7. Out of scope

- `delegate_task` worker affordance, cron/approvals/artifacts migration, `agents.create` allowlist, multi-device presence, deleting ContentView.
