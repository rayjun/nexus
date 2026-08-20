# Agent-Centric Refactor — Design (rev 2)

Date: 2026-08-15 (rev 2, post architecture review)
Status: Reviewed — FIX-AND-GO, incorporating all blocking fixes

## 1. Goal

Restructure the Nexus mobile app around **agents**, not sessions/servers:

1. First screen = agent home (add / browse / chat with agents).
2. "Add agent" is a first-class, direct action.
3. Agents can **collaborate via delegation**.
4. The session list / timeline is removed from the UI. Sessions become an
   internal implementation detail behind each agent's chat history.

## 2. Verified platform facts (architecture-review-validated)

- **Session thread model is sound**: `session.create` returns a usable id;
  `session.resume` follows the compression-continuation chain to the live
  tip; `prompt.submit(session_id:"new")` creates a session on first message.
  → "one persistent thread per agent chat" works with zero wire changes.
- **`agents.list` contract is UNVERIFIED / CONTRADICTED**: the real gateway
  returns `{"processes": [running sessions]}` (methods_tools.py:1652), NOT the
  `{agents:[{id,name,capabilities,session_ids,...}]}` shape the current app
  parses. The app today actually lives on the **recent-sessions fallback**
  (agent.id == a session id). → The refactor must NOT route the app through
  the agent-shaped `agents.list` records until the type is confirmed.
- **`delegate_task` is NOT agent-to-agent messaging**: it spawns a fresh
  child AIAgent with ISOLATED context, inheriting the current agent's
  toolsets, with delegate_task/clarify/memory/send_message/cronjob blocked in
  children. It cannot address a named peer agent with its own identity/history.
  → v1 must honestly be "delegate to a one-off worker", and true cross-agent
  messaging is v2 (requires a server-side agent-scoped session mapping).
- **`hermes import-agent` imports Claude/Codex setups** into a profile; it
  does NOT provision a named, enumerable agent for the app. Not part of the
  add-agent flow.

## 3. Design

### 3.1 Data model (mobile side)

```
Agent
  id            // stable "<serverID>:<sessionID>" — bound to a PERSISTED
                // session id (verified thread), NOT to an agents.list record
  name, icon, description   // enrichment from session title + user edits
  serverID                  // which paired server hosts it
  boundSessionID            // the chat thread on the server (source of truth)
  model, capabilities       // optional; only if a verified server source exists
  status                    // online | offline | lostKeys | unpaired
  lastError                 // last failure reason for the UI
  chatCache                 // local list of messages (ServerStore-style persist)
```

`Agent.id = <serverID>:<sessionID>` — server-qualified and stable across a
session resume (resume resolves the continuation chain to the same live tip).

### 3.2 Screens (each its own file — no ContentView growth)

1. **AgentHomeView** — grid/list of agents (grouped by server), "+ Add
   Agent", first-run bootstrap, offline/lost-keys states, approvals badge.
2. **AgentChatView** — one thread per agent: send, **interrupt** (kept from
   current UI), render markdown + tool calls; stream via the existing
   message.delta event path (ServerConnection already bridges events).
3. **AgentComposeView** — add/edit: name/icon, pick server, choose existing
   session (resume) or start new. Manual "create brand-new agent on server"
   is an explicit v2 stub.
4. **AgentDetailView** — edit/delete (registry-only; deleting the server-side
   session is NOT in the allowlist), status, "delegate to worker".

Shared: `AgentStore` (registry + chat-cache persistence, mirrors ServerStore).

### 3.3 "Add agent" (terminal bootstrap, not a dead end)

- **Empty state** → "pair a server" (reuse PairingView/QR flow) → then import.
- **Import**: from the paired server, list **persisted sessions** (session.list
  — verified shape) and let the user pick one to bind as an agent's thread.
  If `agents.list` proves to return a real agent type (after empirical probe),
  those records can seed name/icon enrichment — but never as the resource an
  agent's chat is bound to.
- **Manual create (v2, labeled)**: stub shown with "available in v2 — use a
  recent session" so the button is never a silent no-op.

### 3.4 Agent collaboration (re-scoped honestly)

- **v1: "Delegate to a worker"** — in AgentChat, a "Delegate…" affordance
  composes a prompt.submit whose goal is scoped-limited (target name + task,
  NOT raw full chat context), the reply is **labeled as subagent output**.
  Child inherits this agent's toolsets and auto-denies dangerous commands
  (server-default). This is real "one agent calls another for work" — but it
  is a stateless worker, not the named peer "speaking".
- **v2 (not promised on launch): true cross-agent messaging** — requires
  server-side agent-scoped session mapping; a "Message agent B" directed
  thread. Explicitly deferred; the design does not promise context bridging
  (which would be an isolation regression).

### 3.5 What gets removed

- Sessions tab, session list, session-detail timeline, session search.
- cron / artifacts tabs (curated server-side; pure UI removal, reversible).
- approvals tab → replaced by a **badge on AgentHome** (approval.list keeps
  working; tapping opens an approvals sheet).
- The recent-sessions→PersistentAgent fallback is REFRAMED as the primary
  import path (pick a session → bind an agent), not deleted.

### 3.6 Server removal / re-pair cascading

- Removing/pairing-lost a server marks every bound agent `offline`/`lostKeys`
  (cache kept), with a "re-pair" entry point on AgentHome for lost-key
  servers. Deleting an agent is registry-only (clears cache + binding).

### 3.7 Relay / agent-side changes

- v1: zero wire-protocol changes (session.* + prompt.submit already
  allowlisted; delegation is a server-side tool).
- `agents.create/update/delete` stay OUT of the allowlist (mutation surface on
  a single E2E channel — not added without a hard gated design).

## 4. Regression guards (AgentChat must not lose today's capability)

- Keep session.interrupt.
- Keep markdown rendering + tool-call display.
- Add streaming incrementally via the existing message.delta event bridge —
  do not regress to "blocking submit then full reload" as the only mode.

## 5. Migration (one atomic flip, one source of truth)

1. Land new per-screen files + AgentStore + Agent model (parallel, hidden).
2. Build AgentHome (bootstrap + import from session.list) + AgentChat.
3. **In the same change**: flip the root to AgentHome and delete the tabbed
   dashboard + session list (no long-lived interim with two sources of truth
   for the agent list and ~2k lines of dead UI coexisting).
4. Add "Delegate to worker" in AgentChat.

## 6. Open questions still blocking implementation (probe first)

- **Probe the real Dashboard WS** (ws://127.0.0.1:9119/api/ws) to pin
  `agents.list`'s actual return type; adjust enrichment source accordingly.
- Approvals placement decision is made (badge + sheet on AgentHome) — no
  further owner needed.
- Delegation approval semantics for mobile: document that child commands
  auto-deny by default (server config `delegation.subagent_auto_approve`).

## 7. Out of scope (this iteration)

- Server-side agent provisioning UX and cross-agent messaging (v2).
- Multi-device presence.
