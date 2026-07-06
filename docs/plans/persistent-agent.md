# Plan: Persistent Agent Feature

## Goal

Replace the ephemeral "Start with a goal" session flow with a persistent Agent concept. An Agent is a long-lived functional entity that accumulates capabilities from past sessions and supports continuous interaction without creating new sessions each time. Add an "Agents" tab to browse existing agents.

## Scope

### Backend (state.db persistence)

1. **New model: `PersistentAgent`**
   - `id`: str (agent_xxx)
   - `name`: str
   - `description`: str (auto-generated from first interaction)
   - `capabilities`: list[str] (accumulated from sessions)
   - `linked_session_ids`: list[str] (sessions this agent learned from)
   - `created_at`: datetime
   - `updated_at`: datetime
   - `last_message_at`: datetime | None

2. **New model: `AgentMessage`**
   - `id`: str
   - `agent_id`: str
   - `role`: "user" | "assistant"
   - `content`: str
   - `created_at`: datetime

3. **DB tables** (in state.db via StateDbMobileStore):
   - `mobile_agents`: id, name, description, capabilities (JSON), linked_session_ids (JSON), created_at, updated_at, last_message_at
   - `mobile_agent_messages`: id, agent_id, role, content, created_at

4. **New API endpoints**:
   - `GET /mobile/v1/agents/persistent` — list persistent agents
   - `POST /mobile/v1/agents/persistent` — create a new persistent agent
   - `DELETE /mobile/v1/agents/persistent/{agent_id}` — delete
   - `GET /mobile/v1/agents/persistent/{agent_id}/messages` — get conversation history
   - `POST /mobile/v1/agents/persistent/{agent_id}/messages` — send a message to the agent
   - `POST /mobile/v1/agents/persistent/{agent_id}/link/{session_id}` — link a session to the agent (accumulate capabilities)

5. **Storage methods** in `StateDbMobileStore`:
   - `_ensure_agent_tables()` — CREATE TABLE IF NOT EXISTS
   - `list_persistent_agents()`
   - `create_persistent_agent(name, description)`
   - `delete_persistent_agent(agent_id)`
   - `get_agent_messages(agent_id)`
   - `send_agent_message(agent_id, content)` — returns assistant placeholder for MVP
   - `link_session_to_agent(agent_id, session_id)` — extracts capabilities from session timeline

### iOS Frontend

1. **Bottom bar**: "Start with a goal" → "Start with an agent"
   - Opens a sheet to create a new persistent agent or pick an existing one

2. **New "Agents" tab** in segmented rail (Inbox, Sessions, **Agents**, Automations, Artifacts)
   - Shows persistent agent cards
   - Tap to enter agent conversation view

3. **Agent conversation view** (full-screen, similar to session chat):
   - Chat bubbles for user/assistant messages
   - Markdown rendering (reuse MarkdownText)
   - Thinking blocks collapsed
   - Bottom input bar for continuous interaction
   - Shows linked sessions and accumulated capabilities

4. **Create agent sheet**:
   - Name input
   - Optional: link to existing sessions
   - Create button

### Mock store support

- `MockMobileStore` also gets persistent agent methods for dev/testing

## Success Criteria

- Agent data persists across gateway restarts (stored in state.db)
- Can create, list, delete agents from the iOS app
- Can send messages to an agent and get responses
- Agent conversation history persists
- "Agents" tab shows all created agents
- Bottom bar says "Start with an agent"
- Existing session/agent-server functionality unchanged

## Test Plan

1. Backend: test persistent agent CRUD in test_state_db_mobile_store.py
2. Backend: test agent message send/receive
3. Backend: test session linking
4. Frontend: build + install + screenshot