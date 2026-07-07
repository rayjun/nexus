from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from secrets import randbelow, token_urlsafe
from typing import Any

from .models import AgentInfo, AgentRequest, AgentMessageRequest, AgentMessageResponse, AgentsResponse, Approval, ApprovalDecision, ApprovalStatus, Artifact, CronJob, CronRun, DeviceInfo, PairingCodeExpired, PairingCompleteRequest, PairingCompleteResponse, PairingStartResponse, PersistentAgent, PersistentAgentCreate, PersistentAgentMessage, PersistentAgentsResponse, SessionSummary, SessionTimeline, StatusResponse, TimelineItem, ToolCall, expires_in


class StateDbMobileStore:
    def __init__(self, db_path: str | Path, agents_path: str | Path | None = None) -> None:
        self.db_path = Path(db_path)
        self.agents_path = Path(agents_path) if agents_path else Path.home() / ".hermes" / "mobile_agents.json"
        self.pending_pairings: dict[str, PairingStartResponse] = {}
        self.device_tokens: dict[str, DeviceInfo] = {}
        self.approval_audit_log: list[dict[str, object]] = []
        now = datetime.now(UTC)
        self.agents: dict[str, AgentInfo] = {
            "agent_vps": AgentInfo(
                id="agent_vps",
                name="VPS Hermes",
                base_url="http://127.0.0.1:8765",
                status="online",
                profile="default",
                model="gpt-5.5",
                created_at=now,
                last_seen_at=now,
            )
        }
        self._load_agents()

    def start_pairing(self) -> PairingStartResponse:
        pairing_id = f"pair_{token_urlsafe(8)}"
        code = f"{randbelow(1_000_000):06d}"
        while code in self.pending_pairings:
            code = f"{randbelow(1_000_000):06d}"
        response = PairingStartResponse(
            pairing_id=pairing_id,
            code=code,
            expires_at=expires_in(10),
            qr_payload=f"hermes://pair?url=http://127.0.0.1:8765&code={code}&fingerprint=state-db",
        )
        self.pending_pairings[code] = response
        return response

    def complete_pairing(self, request: PairingCompleteRequest) -> PairingCompleteResponse | None:
        pairing = self.pending_pairings.pop(request.code, None)
        if not pairing:
            return None
        if pairing.expires_at <= datetime.now(UTC):
            raise PairingCodeExpired()
        device_id = f"dev_{token_urlsafe(8)}"
        device_token = f"hmob_{token_urlsafe(32)}"
        self.device_tokens[device_token] = DeviceInfo(
            id=device_id,
            name=request.device_name,
            platform=request.platform,
            created_at=datetime.now(UTC),
        )
        return PairingCompleteResponse(
            device_id=device_id,
            device_token=device_token,
            capabilities={
                "approvals": True,
                "sessions": True,
                "cron": True,
                "artifacts": True,
                "events": True,
            },
        )

    def device_id_for_token(self, token: str) -> str | None:
        device = self.device_tokens.get(token)
        return device.id if device else None

    def device_token_for_id(self, device_id: str) -> str | None:
        for token, device in self.device_tokens.items():
            if device.id == device_id:
                return token
        return None

    def list_devices(self) -> list[DeviceInfo]:
        return sorted(self.device_tokens.values(), key=lambda device: device.created_at, reverse=True)

    def revoke_device(self, device_id: str) -> bool:
        for token, device in list(self.device_tokens.items()):
            if device.id == device_id:
                del self.device_tokens[token]
                return True
        return False

    def list_agents(self) -> list[AgentInfo]:
        return list(self.agents.values())

    def add_agent(self, request: AgentRequest) -> AgentInfo:
        agent_id = f"agent_{token_urlsafe(8)}"
        agent = AgentInfo(
            id=agent_id,
            name=request.name,
            base_url=request.base_url.rstrip("/"),
            status="offline",
            created_at=datetime.now(UTC),
        )
        self.agents[agent_id] = agent
        self._persist_agents()
        return agent

    def remove_agent(self, agent_id: str) -> bool:
        if agent_id == "agent_vps":
            return False
        removed = self.agents.pop(agent_id, None) is not None
        if removed:
            self._persist_agents()
        return removed

    def update_agent(self, agent_id: str, request: AgentRequest) -> AgentInfo | None:
        if agent_id not in self.agents:
            return None
        agent = self.agents[agent_id]
        updated = AgentInfo(
            id=agent.id,
            name=request.name,
            base_url=request.base_url.rstrip("/"),
            status=agent.status,
            profile=agent.profile,
            model=agent.model,
            created_at=agent.created_at,
            last_seen_at=agent.last_seen_at,
        )
        self.agents[agent_id] = updated
        self._persist_agents()
        return updated

    def _load_agents(self) -> None:
        if not self.agents_path.exists():
            return
        try:
            data = json.loads(self.agents_path.read_text())
        except (OSError, json.JSONDecodeError):
            return
        for item in data.get("agents", []):
            try:
                agent = AgentInfo.model_validate(item)
            except Exception:
                continue
            if agent.id != "agent_vps":
                self.agents[agent.id] = agent
        self._ensure_agent_tables()

    def _persist_agents(self) -> None:
        self.agents_path.parent.mkdir(parents=True, exist_ok=True)
        managed = [agent.model_dump(mode="json") for agent in self.agents.values() if agent.id != "agent_vps"]
        self.agents_path.write_text(json.dumps({"agents": managed}, indent=2, ensure_ascii=False))

    def _ensure_agent_tables(self) -> None:
        with self._connect() as con:
            con.execute(
                """
                CREATE TABLE IF NOT EXISTS mobile_agents (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT DEFAULT '',
                    capabilities TEXT DEFAULT '[]',
                    linked_session_ids TEXT DEFAULT '[]',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    last_message_at REAL
                )
                """
            )
            con.execute(
                """
                CREATE TABLE IF NOT EXISTS mobile_agent_messages (
                    id TEXT PRIMARY KEY,
                    agent_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY (agent_id) REFERENCES mobile_agents(id)
                )
                """
            )
            con.commit()

    def list_persistent_agents(self) -> list[PersistentAgent]:
        self._ensure_agent_tables()
        with self._connect() as con:
            rows = con.execute(
                "SELECT id, name, description, capabilities, linked_session_ids, created_at, updated_at, last_message_at FROM mobile_agents ORDER BY COALESCE(last_message_at, created_at) DESC"
            ).fetchall()
        return [self._persistent_agent(row) for row in rows]

    def create_persistent_agent(self, name: str, description: str = "") -> PersistentAgent:
        self._ensure_agent_tables()
        agent_id = f"agent_{token_urlsafe(8)}"
        now = datetime.now(UTC)
        now_ts = now.timestamp()
        with self._connect() as con:
            con.execute(
                "INSERT INTO mobile_agents (id, name, description, capabilities, linked_session_ids, created_at, updated_at, last_message_at) VALUES (?, ?, ?, '[]', '[]', ?, ?, NULL)",
                (agent_id, name, description, now_ts, now_ts),
            )
            con.commit()
        return PersistentAgent(
            id=agent_id,
            name=name,
            description=description,
            capabilities=[],
            linked_session_ids=[],
            created_at=now,
            updated_at=now,
        )

    def delete_persistent_agent(self, agent_id: str) -> bool:
        self._ensure_agent_tables()
        with self._connect() as con:
            row = con.execute("SELECT id FROM mobile_agents WHERE id = ?", (agent_id,)).fetchone()
            if not row:
                return False
            con.execute("DELETE FROM mobile_agent_messages WHERE agent_id = ?", (agent_id,))
            con.execute("DELETE FROM mobile_agents WHERE id = ?", (agent_id,))
            con.commit()
        return True

    def get_agent_messages(self, agent_id: str) -> list[PersistentAgentMessage]:
        self._ensure_agent_tables()
        with self._connect() as con:
            rows = con.execute(
                "SELECT id, agent_id, role, content, created_at FROM mobile_agent_messages WHERE agent_id = ? ORDER BY created_at ASC, id ASC",
                (agent_id,),
            ).fetchall()
        return [
            PersistentAgentMessage(
                id=row["id"],
                agent_id=row["agent_id"],
                role=row["role"],
                content=row["content"],
                created_at=self._dt(row["created_at"]),
            )
            for row in rows
        ]

    def send_agent_message(self, agent_id: str, content: str) -> tuple[PersistentAgentMessage, PersistentAgentMessage]:
        self._ensure_agent_tables()
        now = datetime.now(UTC)
        now_ts = now.timestamp()
        user_msg_id = f"msg_{token_urlsafe(8)}"
        assistant_msg_id = f"msg_{token_urlsafe(8)}"
        with self._connect() as con:
            row = con.execute("SELECT id, name, description FROM mobile_agents WHERE id = ?", (agent_id,)).fetchone()
            if not row:
                raise ValueError("agent_not_found")
            agent_name = row["name"]
            agent_desc = row["description"] or ""
            con.execute(
                "INSERT INTO mobile_agent_messages (id, agent_id, role, content, created_at) VALUES (?, ?, 'user', ?, ?)",
                (user_msg_id, agent_id, content, now_ts),
            )
            con.commit()

        assistant_content, session_id = self._call_hermes(agent_id, agent_name, agent_desc, content)

        now2 = datetime.now(UTC)
        with self._connect() as con:
            con.execute(
                "INSERT INTO mobile_agent_messages (id, agent_id, role, content, created_at) VALUES (?, ?, 'assistant', ?, ?)",
                (assistant_msg_id, agent_id, assistant_content, now2.timestamp()),
            )
            if session_id:
                linked = con.execute("SELECT linked_session_ids FROM mobile_agents WHERE id = ?", (agent_id,)).fetchone()
                session_ids: list[str] = json.loads(linked["linked_session_ids"] or "[]")
                if session_id not in session_ids:
                    session_ids.append(session_id)
                con.execute(
                    "UPDATE mobile_agents SET last_message_at = ?, updated_at = ?, linked_session_ids = ? WHERE id = ?",
                    (now2.timestamp(), now2.timestamp(), json.dumps(session_ids), agent_id),
                )
            else:
                con.execute(
                    "UPDATE mobile_agents SET last_message_at = ?, updated_at = ? WHERE id = ?",
                    (now2.timestamp(), now2.timestamp(), agent_id),
                )
            con.commit()
        user_msg = PersistentAgentMessage(id=user_msg_id, agent_id=agent_id, role="user", content=content, created_at=now)
        assistant_msg = PersistentAgentMessage(id=assistant_msg_id, agent_id=agent_id, role="assistant", content=assistant_content, created_at=now2)
        return user_msg, assistant_msg

    def _call_hermes(self, agent_id: str, agent_name: str, agent_desc: str, content: str) -> tuple[str, str | None]:
        import httpx

        with self._connect() as con:
            row = con.execute("SELECT linked_session_ids FROM mobile_agents WHERE id = ?", (agent_id,)).fetchone()
            session_ids: list[str] = json.loads(row["linked_session_ids"] or "[]") if row else []

        hermes_session_id = session_ids[-1] if session_ids else f"mobile-agent-{agent_id}"

        api_key = ""
        env_path = Path.home() / ".hermes" / ".env"
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                if line.startswith("API_SERVER_KEY=") and not line.startswith("#"):
                    api_key = line.split("=", 1)[1].strip()
                    break

        if not api_key:
            api_key = "hermes-mobile-local"

        url = "http://127.0.0.1:8642/v1/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "X-Hermes-Session-Id": hermes_session_id,
        }
        body = {
            "model": "hermes-agent",
            "messages": [{"role": "user", "content": content}],
            "max_tokens": 2000,
            "stream": False,
        }

        try:
            resp = httpx.post(url, headers=headers, json=body, timeout=120)
            resp.raise_for_status()
            data = resp.json()
            assistant_content = data["choices"][0]["message"]["content"].strip()
            if not assistant_content:
                assistant_content = "[No response from Hermes]"
            return assistant_content, hermes_session_id
        except Exception as e:
            return f"[Error: unable to call Hermes: {e}]", None

    def link_session_to_agent(self, agent_id: str, session_id: str) -> PersistentAgent | None:
        self._ensure_agent_tables()
        with self._connect() as con:
            row = con.execute("SELECT id, name, description, capabilities, linked_session_ids, created_at, updated_at, last_message_at FROM mobile_agents WHERE id = ?", (agent_id,)).fetchone()
            if not row:
                return None
            linked: list[str] = json.loads(row["linked_session_ids"])
            if session_id not in linked:
                linked.append(session_id)
            timeline = self.get_timeline(session_id)
            caps: list[str] = json.loads(row["capabilities"])
            if timeline:
                for item in timeline.items:
                    if item.tool_calls:
                        for call in item.tool_calls:
                            cap = f"Used {call.name}"
                            if cap not in caps:
                                caps.append(cap)
            now_ts = datetime.now(UTC).timestamp()
            con.execute(
                "UPDATE mobile_agents SET capabilities = ?, linked_session_ids = ?, updated_at = ? WHERE id = ?",
                (json.dumps(caps), json.dumps(linked), now_ts, agent_id),
            )
            con.commit()
            return self._persistent_agent_from_row(row, caps, linked)

    def _persistent_agent(self, row: sqlite3.Row) -> PersistentAgent:
        return PersistentAgent(
            id=row["id"],
            name=row["name"],
            description=row["description"] or "",
            capabilities=json.loads(row["capabilities"] or "[]"),
            linked_session_ids=json.loads(row["linked_session_ids"] or "[]"),
            created_at=self._dt(row["created_at"]),
            updated_at=self._dt(row["updated_at"]),
            last_message_at=self._dt(row["last_message_at"]) if row["last_message_at"] else None,
        )

    def _persistent_agent_from_row(self, row: sqlite3.Row, caps: list[str], linked: list[str]) -> PersistentAgent:
        return PersistentAgent(
            id=row["id"],
            name=row["name"],
            description=row["description"] or "",
            capabilities=caps,
            linked_session_ids=linked,
            created_at=self._dt(row["created_at"]),
            updated_at=self._dt(row["updated_at"]),
            last_message_at=self._dt(row["last_message_at"]) if row["last_message_at"] else None,
        )

    def record_approval_audit(self, approval_id: str, device_id: str, decision: ApprovalStatus, comment: str | None) -> None:
        self.approval_audit_log.append(
            {
                "approval_id": approval_id,
                "device_id": device_id,
                "decision": decision.value,
                "comment": comment,
                "created_at": datetime.now(UTC),
            }
        )

    def list_sessions(self, limit: int = 50) -> list[SessionSummary]:
        with self._connect() as con:
            rows = con.execute(
                """
                SELECT id, title, started_at, ended_at
                FROM sessions
                WHERE archived = 0
                ORDER BY COALESCE(ended_at, started_at) DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [self._session_summary(row) for row in rows]

    def get_timeline(self, session_id: str) -> SessionTimeline | None:
        with self._connect() as con:
            session = con.execute(
                "SELECT id, title, started_at, ended_at FROM sessions WHERE id = ? AND archived = 0",
                (session_id,),
            ).fetchone()
            if not session:
                return None
            messages = con.execute(
                """
                SELECT id, role, content, tool_calls, tool_name, timestamp
                FROM messages
                WHERE session_id = ? AND active = 1
                ORDER BY id ASC
                """,
                (session_id,),
            ).fetchall()
        title = session["title"] or session_id
        return SessionTimeline(
            session_id=session_id,
            title=title,
            items=[item for row in messages if (item := self._timeline_item(row)) is not None],
        )

    def list_approvals(self, status: str | None = None) -> list[Approval]:
        return []

    def list_artifacts(self, limit: int = 50) -> list[Artifact]:
        return []

    def list_cron_jobs(self, limit: int = 50) -> list[CronJob]:
        cron_path = Path.home() / ".hermes" / "cron" / "jobs.json"
        if not cron_path.exists():
            return []
        try:
            data = json.loads(cron_path.read_text())
        except (OSError, json.JSONDecodeError):
            return []
        jobs: list[CronJob] = []
        for item in data.get("jobs", [])[:limit]:
            try:
                next_run = None
                if item.get("next_run_at"):
                    from datetime import datetime as _dt
                    next_run = _dt.fromisoformat(item["next_run_at"])
                last_run = None
                if item.get("state") == "completed" and item.get("last_run_output"):
                    last_run = CronRun(status="success", summary=item.get("last_run_output", "")[:200])
                jobs.append(CronJob(
                    id=item["id"],
                    name=item.get("name", item["id"]),
                    schedule=item.get("schedule_display", item.get("schedule", {}).get("display", "")),
                    enabled=item.get("enabled", True),
                    next_run_at=next_run,
                    last_run=last_run,
                ))
            except Exception:
                continue
        return jobs

    def get_cron_job(self, job_id: str) -> CronJob | None:
        for job in self.list_cron_jobs():
            if job.id == job_id:
                return job
        return None

    def get_status(self) -> "StatusResponse | None":
        config_path = Path.home() / ".hermes" / "config.yaml"
        base_url = "unknown"
        model_name = "unknown"
        provider = "unknown"
        profile = "default"
        if config_path.exists():
            try:
                import yaml
                cfg = yaml.safe_load(config_path.read_text())
                m = cfg.get("model", {})
                base_url = m.get("base_url", base_url)
                model_name = m.get("default", model_name)
                provider = m.get("provider", provider)
                profile = cfg.get("profile", profile)
            except Exception:
                pass
        import socket
        try:
            node_name = socket.gethostname()
        except Exception:
            node_name = "Hermes"
        return StatusResponse(
            node_id=socket.gethostname() if True else "node",
            node_name=node_name,
            status="online",
            gateway_ready=True,
            hermes_version="0.x.x",
            api_version="1.0",
            profile=profile,
            model={"provider": provider, "model": model_name},
            features={
                "events": True,
                "approvals": True,
                "session_timeline": True,
                "cron": True,
                "artifacts": True,
                "push_relay": False,
                "agents": True,
            },
        )

    def get_approval(self, approval_id: str) -> Approval | None:
        return None

    def resolve_approval(self, approval_id: str, status: ApprovalStatus) -> Approval | None:
        return None

    def create_session_from_goal(self, goal: str) -> tuple[SessionSummary, SessionTimeline]:
        raise NotImplementedError("Starting real Hermes sessions is not wired yet")

    def append_goal(self, session_id: str, goal: str) -> tuple[SessionSummary, SessionTimeline] | None:
        now = datetime.now(UTC).timestamp()
        with self._connect() as con:
            session = con.execute(
                "SELECT id FROM sessions WHERE id = ? AND archived = 0",
                (session_id,),
            ).fetchone()
            if not session:
                return None
            con.execute(
                """
                INSERT INTO messages(session_id, role, content, timestamp, active, compacted)
                VALUES (?, 'user', ?, ?, 1, 0)
                """,
                (session_id, goal, now),
            )
            con.execute(
                """
                UPDATE sessions
                SET ended_at = NULL,
                    end_reason = NULL,
                    message_count = COALESCE(message_count, 0) + 1
                WHERE id = ?
                """,
                (session_id,),
            )
            con.commit()
        timeline = self.get_timeline(session_id)
        if not timeline:
            return None
        with self._connect() as con:
            row = con.execute(
                "SELECT id, title, started_at, ended_at FROM sessions WHERE id = ? AND archived = 0",
                (session_id,),
            ).fetchone()
        return self._session_summary(row), timeline

    def _connect(self) -> sqlite3.Connection:
        con = sqlite3.connect(self.db_path)
        con.row_factory = sqlite3.Row
        return con

    def _session_summary(self, row: sqlite3.Row) -> SessionSummary:
        updated_at = row["ended_at"] or row["started_at"]
        return SessionSummary(
            id=row["id"],
            title=row["title"] or row["id"],
            status="completed" if row["ended_at"] else "running",
            created_at=self._dt(row["started_at"]),
            updated_at=self._dt(updated_at),
        )

    def _timeline_item(self, row: sqlite3.Row) -> TimelineItem | None:
        role = row["role"]
        content = row["content"] or ""
        created_at = self._dt(row["timestamp"])
        if role == "user":
            return TimelineItem(type="user_goal", id=f"msg_{row['id']}", text=content, created_at=created_at)
        tool_calls = self._tool_calls(row)
        if tool_calls:
            return TimelineItem(
                type="thinking_block",
                id=f"think_{row['id']}",
                title=content.strip() or "Tool calls",
                tool_calls=tool_calls,
                created_at=created_at,
            )
        if role == "assistant" and content.strip():
            return TimelineItem(
                type="assistant_result",
                id=f"msg_{row['id']}",
                markdown=content,
                created_at=created_at,
            )
        return None

    def _tool_calls(self, row: sqlite3.Row) -> list[ToolCall]:
        raw_calls = row["tool_calls"]
        if raw_calls:
            try:
                parsed = json.loads(raw_calls)
            except json.JSONDecodeError:
                parsed = []
            return [self._tool_call(call, index) for index, call in enumerate(parsed, start=1)]
        tool_name = row["tool_name"]
        if tool_name:
            return [
                ToolCall(
                    id=f"tool_{row['id']}",
                    name=tool_name,
                    summary=f"Ran {tool_name}",
                    status="completed",
                )
            ]
        return []

    def _tool_call(self, call: dict[str, Any], index: int) -> ToolCall:
        function = call.get("function") or {}
        name = function.get("name") or call.get("name") or "tool"
        return ToolCall(
            id=str(call.get("id") or f"tool_{index}"),
            name=name,
            summary=f"Requested {name}",
            status="completed",
        )

    def _dt(self, timestamp: float) -> datetime:
        return datetime.fromtimestamp(float(timestamp), UTC)
