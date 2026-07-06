from __future__ import annotations

from datetime import UTC, datetime, timedelta
from enum import Enum
from typing import Any, Literal

from pydantic import BaseModel, Field


class RiskLevel(str, Enum):
    low = "low"
    medium = "medium"
    high = "high"
    critical = "critical"


class ApprovalStatus(str, Enum):
    pending = "pending"
    approved = "approved"
    denied = "denied"
    expired = "expired"
    cancelled = "cancelled"


class Approval(BaseModel):
    id: str
    session_id: str | None = None
    kind: str
    risk: RiskLevel
    status: ApprovalStatus
    title: str
    summary: str
    reason: str
    details: dict[str, Any]
    actions: list[str] = Field(default_factory=lambda: ["approve", "deny", "ask"])
    created_at: datetime
    expires_at: datetime | None = None


class ApprovalDecision(BaseModel):
    comment: str | None = None
    reason: str | None = None
    biometric_verified: bool = False


class StatusResponse(BaseModel):
    node_id: str
    node_name: str
    status: Literal["online", "offline"]
    gateway_ready: bool
    hermes_version: str
    api_version: str
    profile: str
    model: dict[str, str]
    features: dict[str, bool]


class PairingStartResponse(BaseModel):
    pairing_id: str
    code: str
    expires_at: datetime
    qr_payload: str


class PairingCompleteRequest(BaseModel):
    code: str = Field(min_length=6, max_length=12)
    device_name: str = Field(min_length=1, max_length=120)
    platform: Literal["android", "ios", "desktop", "unknown"] = "unknown"
    public_key: str | None = None


class PairingCompleteResponse(BaseModel):
    device_id: str
    device_token: str
    capabilities: dict[str, bool]


class DeviceInfo(BaseModel):
    id: str
    name: str
    platform: str
    created_at: datetime


class DevicesResponse(BaseModel):
    devices: list[DeviceInfo]


class AgentInfo(BaseModel):
    id: str
    name: str
    base_url: str
    status: Literal["online", "offline"]
    profile: str = "default"
    model: str = "unknown"
    created_at: datetime
    last_seen_at: datetime | None = None


class AgentRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    base_url: str = Field(min_length=1, max_length=500)


class PersistentAgent(BaseModel):
    id: str
    name: str
    description: str = ""
    capabilities: list[str] = Field(default_factory=list)
    linked_session_ids: list[str] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime
    last_message_at: datetime | None = None


class PersistentAgentCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    description: str = Field(default="", max_length=500)


class PersistentAgentMessage(BaseModel):
    id: str
    agent_id: str
    role: Literal["user", "assistant"]
    content: str
    created_at: datetime


class PersistentAgentMessagesResponse(BaseModel):
    messages: list[PersistentAgentMessage]


class PersistentAgentsResponse(BaseModel):
    agents: list[PersistentAgent]


class AgentMessageRequest(BaseModel):
    content: str = Field(min_length=1, max_length=8000)


class AgentMessageResponse(BaseModel):
    user_message: PersistentAgentMessage
    assistant_message: PersistentAgentMessage


class AgentsResponse(BaseModel):
    agents: list[AgentInfo]


class PairingCodeExpired(Exception):
    pass


class Artifact(BaseModel):
    id: str
    session_id: str | None = None
    kind: Literal["file", "image", "log", "link", "data"]
    title: str
    summary: str
    mime_type: str | None = None
    uri: str | None = None
    size_bytes: int | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
    created_at: datetime


class CronRun(BaseModel):
    status: Literal["success", "failed", "running", "skipped"]
    summary: str
    finished_at: datetime | None = None


class CronJob(BaseModel):
    id: str
    name: str
    schedule: str
    enabled: bool
    next_run_at: datetime | None = None
    last_run: CronRun | None = None


class ToolCall(BaseModel):
    id: str
    name: str
    summary: str
    status: Literal["running", "completed", "failed", "waiting_approval", "skipped"]
    duration_ms: int | None = None
    error: str | None = None


class TimelineItem(BaseModel):
    type: Literal["user_goal", "thinking_block", "assistant_result"]
    id: str
    created_at: datetime
    text: str | None = None
    title: str | None = None
    tool_calls: list[ToolCall] | None = None
    markdown: str | None = None


class SessionTimeline(BaseModel):
    session_id: str
    title: str
    items: list[TimelineItem]


class GoalRequest(BaseModel):
    goal: str = Field(min_length=1, max_length=4000)


class SessionSummary(BaseModel):
    id: str
    title: str
    status: Literal["running", "waiting_approval", "completed", "failed"]
    created_at: datetime
    updated_at: datetime


class GoalResponse(BaseModel):
    session: SessionSummary
    timeline: SessionTimeline


def now_utc() -> datetime:
    return datetime.now(UTC)


def expires_in(minutes: int) -> datetime:
    return now_utc() + timedelta(minutes=minutes)
