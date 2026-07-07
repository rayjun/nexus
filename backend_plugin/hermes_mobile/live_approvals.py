from __future__ import annotations

import base64
import importlib
from datetime import UTC, datetime
from typing import Any

from .models import AgentInfo, AgentRequest, Approval, ApprovalStatus, Artifact, CronJob, DeviceInfo, PairingCompleteRequest, PairingCompleteResponse, PairingStartResponse, RiskLevel, SessionSummary, SessionTimeline


class HermesApprovalBridge:
    def __init__(self, approval_module: Any | None = None) -> None:
        self.approval_module = approval_module

    def list_approvals(self, status: str | None = None) -> list[Approval]:
        if status and status != ApprovalStatus.pending:
            return []
        module = self._module()
        if module is None:
            return []
        approvals: list[Approval] = []
        lock = getattr(module, "_lock", None)
        if lock is None:
            queues = dict(getattr(module, "_gateway_queues", {}) or {})
        else:
            with lock:
                queues = {key: list(value) for key, value in (getattr(module, "_gateway_queues", {}) or {}).items()}
        for session_key, queue in queues.items():
            if queue:
                approvals.append(self._approval_from_entry(session_key, 0, queue[0], ApprovalStatus.pending))
        return approvals

    def get_approval(self, approval_id: str) -> Approval | None:
        parsed = self._parse_id(approval_id)
        if parsed is None:
            return None
        session_key, index = parsed
        module = self._module()
        if module is None:
            return None
        lock = getattr(module, "_lock", None)
        if lock is None:
            queue = list((getattr(module, "_gateway_queues", {}) or {}).get(session_key, []))
        else:
            with lock:
                queue = list((getattr(module, "_gateway_queues", {}) or {}).get(session_key, []))
        if index >= len(queue):
            return None
        return self._approval_from_entry(session_key, index, queue[index], ApprovalStatus.pending)

    def resolve_approval(self, approval_id: str, status: ApprovalStatus) -> Approval | None:
        pending = self.get_approval(approval_id)
        if pending is None:
            return None
        parsed = self._parse_id(approval_id)
        if parsed is None:
            return None
        session_key, index = parsed
        if index != 0:
            return None
        module = self._module()
        if module is None:
            return None
        choice = "deny" if status == ApprovalStatus.denied else "once"
        resolved = module.resolve_gateway_approval(session_key, choice, resolve_all=False)
        if not resolved:
            return None
        return pending.model_copy(update={"status": status})

    def _module(self) -> Any | None:
        if self.approval_module is not None:
            return self.approval_module
        try:
            self.approval_module = importlib.import_module("tools.approval")
        except Exception:
            return None
        return self.approval_module

    def _approval_from_entry(self, session_key: str, index: int, entry: Any, status: ApprovalStatus) -> Approval:
        data = dict(getattr(entry, "data", {}) or {})
        command = str(data.get("command") or "")
        description = str(data.get("description") or "Hermes is waiting for approval.")
        pattern_keys = data.get("pattern_keys") or [data.get("pattern_key")]
        pattern_keys = [key for key in pattern_keys if key]
        return Approval(
            id=self._approval_id(session_key, index),
            session_id=session_key,
            kind="terminal_command",
            risk=RiskLevel.high,
            status=status,
            title="Approve terminal command",
            summary=description,
            reason="Hermes is blocked waiting for a mobile approval decision.",
            details={
                "session_key": session_key,
                "command": command,
                "description": description,
                "pattern_key": data.get("pattern_key"),
                "pattern_keys": pattern_keys,
                "allow_permanent": bool(data.get("allow_permanent", False)),
            },
            actions=["approve", "deny"],
            created_at=datetime.now(UTC),
            expires_at=None,
        )

    def _approval_id(self, session_key: str, index: int) -> str:
        encoded = base64.urlsafe_b64encode(session_key.encode()).decode().rstrip("=")
        return f"live_approval_{encoded}_{index}"

    def _parse_id(self, approval_id: str) -> tuple[str, int] | None:
        prefix = "live_approval_"
        if not approval_id.startswith(prefix):
            return None
        tail = approval_id[len(prefix) :]
        encoded, sep, index_text = tail.rpartition("_")
        if not sep:
            return None
        try:
            padding = "=" * (-len(encoded) % 4)
            session_key = base64.urlsafe_b64decode((encoded + padding).encode()).decode()
            index = int(index_text)
        except Exception:
            return None
        return session_key, index


class LiveApprovalMobileStore:
    def __init__(self, base_store: Any, bridge: HermesApprovalBridge | None = None) -> None:
        self.base_store = base_store
        self.bridge = bridge or HermesApprovalBridge()

    def list_sessions(self, limit: int = 50) -> list[SessionSummary]:
        return self.base_store.list_sessions(limit=limit)

    def start_pairing(self) -> PairingStartResponse:
        return self.base_store.start_pairing()

    def complete_pairing(self, request: PairingCompleteRequest) -> PairingCompleteResponse | None:
        return self.base_store.complete_pairing(request)

    def device_id_for_token(self, token: str) -> str | None:
        return self.base_store.device_id_for_token(token)

    def device_token_for_id(self, device_id: str) -> str | None:
        return self.base_store.device_token_for_id(device_id)

    def list_devices(self) -> list[DeviceInfo]:
        return self.base_store.list_devices()

    def revoke_device(self, device_id: str) -> bool:
        return self.base_store.revoke_device(device_id)

    def list_agents(self) -> list[AgentInfo]:
        return self.base_store.list_agents()

    def add_agent(self, request: AgentRequest) -> AgentInfo:
        return self.base_store.add_agent(request)

    def get_status(self):
        if hasattr(self.base_store, "get_status"):
            return self.base_store.get_status()
        return None

    def remove_agent(self, agent_id: str) -> bool:
        return self.base_store.remove_agent(agent_id)

    def record_approval_audit(self, approval_id: str, device_id: str, decision: ApprovalStatus, comment: str | None) -> None:
        self.base_store.record_approval_audit(approval_id, device_id, decision, comment)

    def list_artifacts(self, limit: int = 50) -> list[Artifact]:
        return self.base_store.list_artifacts(limit=limit)

    def list_cron_jobs(self, limit: int = 50) -> list[CronJob]:
        return self.base_store.list_cron_jobs(limit=limit)

    def get_cron_job(self, job_id: str) -> CronJob | None:
        return self.base_store.get_cron_job(job_id)

    def list_approvals(self, status: str | None = None) -> list[Approval]:
        return [*self.base_store.list_approvals(status=status), *self.bridge.list_approvals(status=status)]

    def get_approval(self, approval_id: str) -> Approval | None:
        return self.bridge.get_approval(approval_id) or self.base_store.get_approval(approval_id)

    def resolve_approval(self, approval_id: str, status: ApprovalStatus) -> Approval | None:
        return self.bridge.resolve_approval(approval_id, status) or self.base_store.resolve_approval(approval_id, status)

    def create_session_from_goal(self, goal: str) -> tuple[SessionSummary, SessionTimeline]:
        return self.base_store.create_session_from_goal(goal)

    def append_goal(self, session_id: str, goal: str) -> tuple[SessionSummary, SessionTimeline] | None:
        return self.base_store.append_goal(session_id, goal)

    def get_timeline(self, session_id: str) -> SessionTimeline | None:
        return self.base_store.get_timeline(session_id)
