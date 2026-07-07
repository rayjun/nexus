from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime
from secrets import randbelow, token_urlsafe

from .models import (
    AgentInfo,
    AgentRequest,
    Approval,
    ApprovalStatus,
    Artifact,
    CronJob,
    CronRun,
    DeviceInfo,
    PairingCodeExpired,
    PairingCompleteRequest,
    PairingCompleteResponse,
    PairingStartResponse,
    PersistentAgent,
    PersistentAgentMessage,
    RiskLevel,
    SessionSummary,
    SessionTimeline,
    StatusResponse,
    TimelineItem,
    ToolCall,
    expires_in,
    now_utc,
)


@dataclass
class PendingPairing:
    pairing_id: str
    code: str
    expires_at: datetime


@dataclass
class DeviceRegistration:
    device_id: str
    device_token: str
    device_name: str
    platform: str
    created_at: datetime


@dataclass
class ApprovalAuditEntry:
    approval_id: str
    device_id: str
    decision: str
    comment: str | None
    created_at: datetime


class MockMobileStore:
    def __init__(self) -> None:
        created_at = now_utc()
        self.approvals: dict[str, Approval] = {
            "appr_mock_git_push": Approval(
                id="appr_mock_git_push",
                session_id="sess_mock_contribution",
                kind="terminal_command",
                risk=RiskLevel.high,
                status=ApprovalStatus.pending,
                title="Run git push",
                summary="Hermes wants to push branch fix/mobile-api.",
                reason="The requested change passed tests and needs to be pushed for review.",
                details={
                    "command": "git push origin fix/mobile-api",
                    "cwd": "/home/ubuntu/projects/hermes-agent",
                    "repo": "rayjun/hermes-agent",
                    "branch": "fix/mobile-api",
                    "files_changed": 3,
                    "tests": "128 passed",
                },
                created_at=created_at,
                expires_at=expires_in(15),
            )
        }
        self.sessions: dict[str, SessionSummary] = {
            "sess_mock_contribution": SessionSummary(
                id="sess_mock_contribution",
                title="Hermes-Agent contribution #2",
                status="waiting_approval",
                created_at=created_at,
                updated_at=created_at,
            )
        }
        self.artifacts: dict[str, Artifact] = {
            "art_mock_patch": Artifact(
                id="art_mock_patch",
                session_id="sess_mock_contribution",
                kind="file",
                title="mobile-api.patch",
                summary="Patch generated for Hermes Mobile API adapter changes.",
                mime_type="text/x-diff",
                uri="file:///home/ubuntu/projects/hermes-mobile/mobile-api.patch",
                size_bytes=18432,
                metadata={"language": "diff", "repo": "rayjun/hermes-mobile"},
                created_at=created_at,
            ),
            "art_mock_log": Artifact(
                id="art_mock_log",
                session_id="sess_mock_contribution",
                kind="log",
                title="gateway-smoke.log",
                summary="Smoke test output for /mobile/v1 gateway endpoints.",
                mime_type="text/plain",
                uri="file:///home/ubuntu/projects/hermes-mobile/gateway-smoke.log",
                size_bytes=2048,
                metadata={"command": "pytest tests/test_mobile_gateway_mock.py"},
                created_at=created_at,
            ),
        }
        self.cron_jobs: dict[str, CronJob] = {
            "cron_mock_morning_report": CronJob(
                id="cron_mock_morning_report",
                name="DeFi morning report",
                schedule="0 9 * * *",
                enabled=True,
                next_run_at=expires_in(90),
                last_run=CronRun(
                    status="success",
                    summary="Delivered concise DeFi morning report.",
                    finished_at=created_at,
                ),
            ),
            "cron_mock_memory_sync": CronJob(
                id="cron_mock_memory_sync",
                name="Hermes memory sync",
                schedule="every hour",
                enabled=True,
                next_run_at=expires_in(60),
                last_run=CronRun(
                    status="success",
                    summary="Pushed memory and skills to private repository.",
                    finished_at=created_at,
                ),
            ),
        }
        self.timelines: dict[str, SessionTimeline] = {
            "sess_mock_contribution": SessionTimeline(
                session_id="sess_mock_contribution",
                title="Hermes-Agent contribution #2",
                items=[
                    TimelineItem(
                        type="user_goal",
                        id="msg_1",
                        text="继续找 pr",
                        created_at=created_at,
                    ),
                    TimelineItem(
                        type="thinking_block",
                        id="think_1",
                        title="Thinking",
                        created_at=created_at,
                        tool_calls=[
                            ToolCall(
                                id="tool_1",
                                name="search_files",
                                summary="Searched files",
                                status="completed",
                                duration_ms=458,
                            ),
                            ToolCall(
                                id="tool_2",
                                name="read_file",
                                summary="Read hermes_cli/main.py",
                                status="completed",
                                duration_ms=118,
                            ),
                            ToolCall(
                                id="tool_3",
                                name="model_call",
                                summary="API call failed after 3 retries",
                                status="failed",
                                error="Connection error",
                            ),
                        ],
                    ),
                    TimelineItem(
                        type="assistant_result",
                        id="msg_2",
                        markdown="找到一个适合的小问题，可以继续分析并准备最小 diff。",
                        created_at=created_at,
                    ),
                ],
            )
        }

        self.pending_pairings: dict[str, PendingPairing] = {}
        self.device_tokens: dict[str, DeviceRegistration] = {}
        self.approval_audit_log: list[ApprovalAuditEntry] = []
        self.agents: dict[str, AgentInfo] = {
            "agent_vps": AgentInfo(
                id="agent_vps",
                name="VPS Hermes",
                base_url="http://127.0.0.1:8765",
                status="online",
                profile="default",
                model="gpt-5.5",
                created_at=created_at,
                last_seen_at=created_at,
            )
        }

    def start_pairing(self) -> PairingStartResponse:
        pairing_id = f"pair_{token_urlsafe(8)}"
        code = f"{randbelow(1_000_000):06d}"
        while code in self.pending_pairings:
            code = f"{randbelow(1_000_000):06d}"
        expires_at = expires_in(10)
        self.pending_pairings[code] = PendingPairing(pairing_id=pairing_id, code=code, expires_at=expires_at)
        return PairingStartResponse(
            pairing_id=pairing_id,
            code=code,
            expires_at=expires_at,
            qr_payload=f"hermes://pair?url=http://127.0.0.1:8765&code={code}&fingerprint=mock",
        )

    def complete_pairing(self, request: PairingCompleteRequest) -> PairingCompleteResponse | None:
        pairing = self.pending_pairings.pop(request.code, None)
        if not pairing:
            return None
        if pairing.expires_at <= now_utc():
            raise PairingCodeExpired()
        device_id = f"dev_{token_urlsafe(8)}"
        device_token = f"hmob_{token_urlsafe(32)}"
        self.device_tokens[device_token] = DeviceRegistration(
            device_id=device_id,
            device_token=device_token,
            device_name=request.device_name,
            platform=request.platform,
            created_at=now_utc(),
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
        return device.device_id if device else None

    def device_token_for_id(self, device_id: str) -> str | None:
        for token, device in self.device_tokens.items():
            if device.device_id == device_id:
                return token
        return None

    def list_devices(self) -> list[DeviceInfo]:
        devices = sorted(self.device_tokens.values(), key=lambda device: device.created_at, reverse=True)
        return [
            DeviceInfo(
                id=device.device_id,
                name=device.device_name,
                platform=device.platform,
                created_at=device.created_at,
            )
            for device in devices
        ]

    def revoke_device(self, device_id: str) -> bool:
        for token, device in list(self.device_tokens.items()):
            if device.device_id == device_id:
                del self.device_tokens[token]
                return True
        return False

    def list_agents(self) -> list[AgentInfo]:
        return deepcopy(list(self.agents.values()))

    def add_agent(self, request: AgentRequest) -> AgentInfo:
        agent_id = f"agent_{token_urlsafe(8)}"
        agent = AgentInfo(
            id=agent_id,
            name=request.name,
            base_url=request.base_url.rstrip("/"),
            status="offline",
            created_at=now_utc(),
        )
        self.agents[agent_id] = agent
        return deepcopy(agent)

    def remove_agent(self, agent_id: str) -> bool:
        if agent_id == "agent_vps":
            return False
        return self.agents.pop(agent_id, None) is not None

    def update_agent(self, agent_id: str, request: AgentRequest) -> AgentInfo | None:
        agent = self.agents.get(agent_id)
        if not agent:
            return None
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
        return deepcopy(updated)

    def get_status(self) -> "StatusResponse | None":
        return None

    def list_persistent_agents(self) -> list[PersistentAgent]:
        return []

    def create_persistent_agent(self, name: str, description: str = "") -> PersistentAgent:
        now = now_utc()
        return PersistentAgent(
            id=f"agent_{token_urlsafe(8)}",
            name=name,
            description=description,
            created_at=now,
            updated_at=now,
        )

    def delete_persistent_agent(self, agent_id: str) -> bool:
        return False

    def get_agent_messages(self, agent_id: str) -> list[PersistentAgentMessage]:
        return []

    def send_agent_message(self, agent_id: str, content: str) -> tuple[PersistentAgentMessage, PersistentAgentMessage]:
        now = now_utc()
        user_msg = PersistentAgentMessage(id=f"msg_{token_urlsafe(8)}", agent_id=agent_id, role="user", content=content, created_at=now)
        assistant_msg = PersistentAgentMessage(id=f"msg_{token_urlsafe(8)}", agent_id=agent_id, role="assistant", content="Placeholder response.", created_at=now)
        return user_msg, assistant_msg

    def link_session_to_agent(self, agent_id: str, session_id: str) -> PersistentAgent | None:
        return None

    def record_approval_audit(self, approval_id: str, device_id: str, decision: ApprovalStatus, comment: str | None) -> None:
        self.approval_audit_log.append(
            ApprovalAuditEntry(
                approval_id=approval_id,
                device_id=device_id,
                decision=decision.value,
                comment=comment,
                created_at=now_utc(),
            )
        )

    def list_artifacts(self, limit: int = 50) -> list[Artifact]:
        artifacts = sorted(self.artifacts.values(), key=lambda artifact: artifact.created_at, reverse=True)
        return deepcopy(artifacts[:limit])

    def list_cron_jobs(self, limit: int = 50) -> list[CronJob]:
        return deepcopy(list(self.cron_jobs.values())[:limit])

    def get_cron_job(self, job_id: str) -> CronJob | None:
        job = self.cron_jobs.get(job_id)
        return deepcopy(job) if job else None

    def list_sessions(self, limit: int = 50) -> list[SessionSummary]:
        sessions = sorted(self.sessions.values(), key=lambda session: session.updated_at, reverse=True)
        return deepcopy(sessions[:limit])

    def list_approvals(self, status: str | None = None) -> list[Approval]:
        approvals = list(self.approvals.values())
        if status:
            approvals = [approval for approval in approvals if approval.status == status]
        return deepcopy(approvals)

    def get_approval(self, approval_id: str) -> Approval | None:
        approval = self.approvals.get(approval_id)
        return deepcopy(approval) if approval else None

    def resolve_approval(self, approval_id: str, status: ApprovalStatus) -> Approval | None:
        approval = self.approvals.get(approval_id)
        if not approval:
            return None
        approval.status = status
        return deepcopy(approval)

    def get_timeline(self, session_id: str) -> SessionTimeline | None:
        timeline = self.timelines.get(session_id)
        return deepcopy(timeline) if timeline else None

    def create_session_from_goal(self, goal: str) -> tuple[SessionSummary, SessionTimeline]:
        created_at = now_utc()
        session_id = f"sess_goal_{len(self.sessions) + 1}"
        session = SessionSummary(
            id=session_id,
            title=goal,
            status="running",
            created_at=created_at,
            updated_at=created_at,
        )
        timeline = SessionTimeline(
            session_id=session_id,
            title=goal,
            items=[
                TimelineItem(
                    type="user_goal",
                    id=f"{session_id}_goal_1",
                    text=goal,
                    created_at=created_at,
                ),
                self._thinking_item(session_id=session_id, index=1, created_at=created_at),
            ],
        )
        self.sessions[session_id] = session
        self.timelines[session_id] = timeline
        return deepcopy(session), deepcopy(timeline)

    def append_goal(self, session_id: str, goal: str) -> tuple[SessionSummary, SessionTimeline] | None:
        session = self.sessions.get(session_id)
        timeline = self.timelines.get(session_id)
        if not session or not timeline:
            return None
        created_at = now_utc()
        next_index = len(timeline.items) + 1
        timeline.items.append(
            TimelineItem(
                type="user_goal",
                id=f"{session_id}_goal_{next_index}",
                text=goal,
                created_at=created_at,
            )
        )
        timeline.items.append(self._thinking_item(session_id=session_id, index=next_index + 1, created_at=created_at))
        session.status = "running"
        session.updated_at = created_at
        return deepcopy(session), deepcopy(timeline)

    def _thinking_item(self, session_id: str, index: int, created_at) -> TimelineItem:
        return TimelineItem(
            type="thinking_block",
            id=f"{session_id}_think_{index}",
            title="Queued",
            created_at=created_at,
            tool_calls=[
                ToolCall(
                    id=f"{session_id}_tool_{index}",
                    name="mobile_goal",
                    summary="Accepted goal from mobile command bar",
                    status="running",
                )
            ],
        )
