from __future__ import annotations

import hashlib
import hmac
import os
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Optional, Protocol

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, WebSocket

from .live_approvals import LiveApprovalMobileStore
from .models import AgentInfo, AgentRequest, AgentMessageRequest, AgentMessageResponse, AgentsResponse, Approval, ApprovalDecision, ApprovalStatus, Artifact, CronJob, DeviceInfo, DevicesResponse, GoalRequest, GoalResponse, PairingCodeExpired, PairingCompleteRequest, PairingCompleteResponse, PairingStartResponse, PersistentAgent, PersistentAgentCreate, PersistentAgentUpdate, PersistentAgentMessage, PersistentAgentsResponse, SessionSummary, SessionTimeline, StatusResponse, TimelineItem, ToolCall, expires_in
from .real_store import StateDbMobileStore
from .storage import MockMobileStore


class MobileStore(Protocol):
    def start_pairing(self) -> PairingStartResponse: ...
    def complete_pairing(self, request: PairingCompleteRequest) -> PairingCompleteResponse | None: ...
    def device_id_for_token(self, token: str) -> str | None: ...
    def device_token_for_id(self, device_id: str) -> str | None: ...
    def list_devices(self) -> list[DeviceInfo]: ...
    def revoke_device(self, device_id: str) -> bool: ...
    def list_agents(self) -> list[AgentInfo]: ...
    def add_agent(self, request: AgentRequest) -> AgentInfo: ...
    def update_agent(self, agent_id: str, request: AgentRequest) -> AgentInfo | None: ...
    def get_status(self) -> "StatusResponse | None": ...
    def remove_agent(self, agent_id: str) -> bool: ...
    def list_persistent_agents(self) -> list["PersistentAgent"]: ...
    def create_persistent_agent(self, name: str, description: str = "", icon: str = "sparkles") -> "PersistentAgent": ...
    def update_persistent_agent(self, agent_id: str, request: "PersistentAgentUpdate") -> "PersistentAgent | None": ...
    def delete_persistent_agent(self, agent_id: str) -> bool: ...
    def get_agent_messages(self, agent_id: str, limit: int = 50, offset: int = 0) -> list["PersistentAgentMessage"]: ...
    def send_agent_message(self, agent_id: str, content: str) -> tuple["PersistentAgentMessage", "PersistentAgentMessage"]: ...
    def link_session_to_agent(self, agent_id: str, session_id: str) -> "PersistentAgent | None": ...
    def record_approval_audit(self, approval_id: str, device_id: str, decision: ApprovalStatus, comment: str | None) -> None: ...
    def list_sessions(self, limit: int = 50) -> list[SessionSummary]: ...
    def list_artifacts(self, limit: int = 50) -> list[Artifact]: ...
    def list_cron_jobs(self, limit: int = 50) -> list[CronJob]: ...
    def get_cron_job(self, job_id: str) -> CronJob | None: ...
    def list_approvals(self, status: str | None = None) -> list[Approval]: ...
    def get_approval(self, approval_id: str) -> Approval | None: ...
    def resolve_approval(self, approval_id: str, status: ApprovalStatus) -> Approval | None: ...
    def create_session_from_goal(self, goal: str) -> tuple[SessionSummary, SessionTimeline]: ...
    def append_goal(self, session_id: str, goal: str) -> tuple[SessionSummary, SessionTimeline] | None: ...
    def get_timeline(self, session_id: str) -> SessionTimeline | None: ...


def create_default_store() -> MobileStore:
    state_db = os.getenv("HERMES_MOBILE_STATE_DB")
    base_store: MobileStore
    if state_db:
        base_store = StateDbMobileStore(state_db)
    else:
        default_state = Path.home() / ".hermes" / "state.db"
        if os.getenv("HERMES_MOBILE_USE_STATE_DB") == "1" and default_state.exists():
            base_store = StateDbMobileStore(default_state)
        else:
            base_store = MockMobileStore()
    if os.getenv("HERMES_MOBILE_USE_LIVE_APPROVALS") == "1":
        return LiveApprovalMobileStore(base_store)
    return base_store


def create_app(store: MobileStore | None = None) -> FastAPI:
    app = FastAPI(title="Nexus Mobile Gateway", version="0.1.0")
    store = store or create_default_store()
    used_signed_nonces: set[tuple[str, str]] = set()

    @app.get("/mobile/v1/status", response_model=StatusResponse)
    def status() -> StatusResponse:
        store_status = store.get_status() if hasattr(store, "get_status") else None
        if store_status:
            return store_status
        import socket
        try:
            node_name = socket.gethostname()
        except Exception:
            node_name = "Hermes"
        return StatusResponse(
            node_id=node_name,
            node_name=node_name,
            status="online",
            gateway_ready=True,
            hermes_version="0.x.x",
            api_version="1.0",
            profile="default",
            model={"provider": "unknown", "model": "unknown"},
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

    @app.post("/mobile/v1/pair/start", response_model=PairingStartResponse)
    def pair_start() -> PairingStartResponse:
        return store.start_pairing()

    @app.post("/mobile/v1/pair/complete", response_model=PairingCompleteResponse)
    def pair_complete(request: PairingCompleteRequest) -> PairingCompleteResponse:
        try:
            paired = store.complete_pairing(request)
        except PairingCodeExpired:
            raise HTTPException(status_code=410, detail="pairing_code_expired") from None
        if not paired:
            raise HTTPException(status_code=404, detail="pairing_code_not_found")
        return paired

    def require_device(request: Request, authorization: Optional[str] = Header(default=None)) -> str:
        if not authorization:
            raise HTTPException(status_code=401, detail="mobile_auth_required")
        bearer_prefix = "Bearer "
        if authorization.startswith(bearer_prefix):
            device_id = store.device_id_for_token(authorization.removeprefix(bearer_prefix).strip())
            if not device_id:
                raise HTTPException(status_code=401, detail="mobile_auth_required")
            return device_id
        signed_prefix = "HermesDevice "
        if authorization.startswith(signed_prefix):
            fields = dict(re.findall(r'(device_id|timestamp|nonce|signature)="([^"]+)"', authorization.removeprefix(signed_prefix)))
            device_id = fields.get("device_id")
            timestamp = fields.get("timestamp")
            nonce = fields.get("nonce")
            signature = fields.get("signature")
            if not device_id or not timestamp or not nonce or not signature:
                raise HTTPException(status_code=401, detail="mobile_auth_required")
            device_token = store.device_token_for_id(device_id)
            if not device_token:
                raise HTTPException(status_code=401, detail="mobile_auth_required")
            try:
                signed_at = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            except ValueError:
                raise HTTPException(status_code=401, detail="mobile_auth_required") from None
            if abs((datetime.now(UTC) - signed_at).total_seconds()) > 300:
                raise HTTPException(status_code=401, detail="mobile_auth_required")
            nonce_key = (device_id, nonce)
            if nonce_key in used_signed_nonces:
                raise HTTPException(status_code=401, detail="mobile_auth_required")
            target = request.url.path
            if request.url.query:
                target = f"{target}?{request.url.query}"
            message = f"{request.method.upper()}\n{target}\n{timestamp}\n{nonce}"
            expected = hmac.new(device_token.encode(), message.encode(), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(expected, signature):
                raise HTTPException(status_code=401, detail="mobile_auth_required")
            used_signed_nonces.add(nonce_key)
            return device_id
        raise HTTPException(status_code=401, detail="mobile_auth_required")

    @app.get("/mobile/v1/devices", response_model=DevicesResponse)
    def list_devices(device_id: str = Depends(require_device)) -> DevicesResponse:
        return DevicesResponse(devices=store.list_devices())

    @app.delete("/mobile/v1/devices/{device_id}", status_code=204)
    def revoke_device(device_id: str, requester_device_id: str = Depends(require_device)) -> Response:
        if not store.revoke_device(device_id):
            raise HTTPException(status_code=404, detail="device_not_found")
        return Response(status_code=204)

    @app.get("/mobile/v1/agents", response_model=AgentsResponse)
    def list_agents(device_id: str = Depends(require_device)) -> AgentsResponse:
        return AgentsResponse(agents=store.list_agents())

    @app.post("/mobile/v1/agents", response_model=AgentInfo)
    def add_agent(request: AgentRequest, device_id: str = Depends(require_device)) -> AgentInfo:
        return store.add_agent(request)

    @app.put("/mobile/v1/agents/{agent_id}", response_model=AgentInfo)
    def update_agent(agent_id: str, request: AgentRequest, device_id: str = Depends(require_device)) -> AgentInfo:
        if hasattr(store, "update_agent"):
            updated = store.update_agent(agent_id, request)
            if not updated:
                raise HTTPException(status_code=404, detail="agent_not_found")
            return updated
        raise HTTPException(status_code=501, detail="not_supported")

    @app.delete("/mobile/v1/agents/{agent_id}", status_code=204)
    def remove_agent(agent_id: str, device_id: str = Depends(require_device)) -> Response:
        if not store.remove_agent(agent_id):
            raise HTTPException(status_code=404, detail="agent_not_found")
        return Response(status_code=204)

    @app.get("/mobile/v1/agents/persistent", response_model=PersistentAgentsResponse)
    def list_persistent_agents(device_id: str = Depends(require_device)) -> PersistentAgentsResponse:
        if hasattr(store, "list_persistent_agents"):
            return PersistentAgentsResponse(agents=store.list_persistent_agents())
        return PersistentAgentsResponse(agents=[])

    @app.post("/mobile/v1/agents/persistent", response_model=PersistentAgent)
    def create_persistent_agent(request: PersistentAgentCreate, device_id: str = Depends(require_device)) -> PersistentAgent:
        if hasattr(store, "create_persistent_agent"):
            return store.create_persistent_agent(request.name, request.description, request.icon)
        raise HTTPException(status_code=501, detail="not_supported")

    @app.put("/mobile/v1/agents/persistent/{agent_id}", response_model=PersistentAgent)
    def update_persistent_agent(agent_id: str, request: PersistentAgentUpdate, device_id: str = Depends(require_device)) -> PersistentAgent:
        if hasattr(store, "update_persistent_agent"):
            result = store.update_persistent_agent(agent_id, request)
            if not result:
                raise HTTPException(status_code=404, detail="agent_not_found")
            return result
        raise HTTPException(status_code=501, detail="not_supported")

    @app.delete("/mobile/v1/agents/persistent/{agent_id}", status_code=204)
    def delete_persistent_agent(agent_id: str, device_id: str = Depends(require_device)) -> Response:
        if hasattr(store, "delete_persistent_agent"):
            if not store.delete_persistent_agent(agent_id):
                raise HTTPException(status_code=404, detail="agent_not_found")
            return Response(status_code=204)
        raise HTTPException(status_code=501, detail="not_supported")

    @app.get("/mobile/v1/agents/persistent/{agent_id}/messages")
    def list_agent_messages(agent_id: str, limit: int = Query(default=50, ge=1, le=200), offset: int = Query(default=0, ge=0), device_id: str = Depends(require_device)) -> dict[str, object]:
        if hasattr(store, "get_agent_messages"):
            return {"messages": store.get_agent_messages(agent_id, limit=limit, offset=offset)}
        return {"messages": []}

    @app.post("/mobile/v1/agents/persistent/{agent_id}/messages", response_model=AgentMessageResponse)
    def send_agent_message(agent_id: str, request: AgentMessageRequest, device_id: str = Depends(require_device)) -> AgentMessageResponse:
        if hasattr(store, "send_agent_message"):
            try:
                user_msg, assistant_msg = store.send_agent_message(agent_id, request.content)
                return AgentMessageResponse(user_message=user_msg, assistant_message=assistant_msg)
            except ValueError:
                raise HTTPException(status_code=404, detail="agent_not_found") from None
        raise HTTPException(status_code=501, detail="not_supported")

    @app.post("/mobile/v1/agents/persistent/{agent_id}/link/{session_id}", response_model=PersistentAgent)
    def link_session(agent_id: str, session_id: str, device_id: str = Depends(require_device)) -> PersistentAgent:
        if hasattr(store, "link_session_to_agent"):
            result = store.link_session_to_agent(agent_id, session_id)
            if not result:
                raise HTTPException(status_code=404, detail="agent_not_found")
            return result
        raise HTTPException(status_code=501, detail="not_supported")

    @app.get("/mobile/v1/approvals")
    def list_approvals(status: str | None = Query(default=None), device_id: str = Depends(require_device)) -> dict[str, object]:
        return {"approvals": store.list_approvals(status=status)}

    @app.get("/mobile/v1/approvals/{approval_id}")
    def get_approval(approval_id: str, device_id: str = Depends(require_device)) -> object:
        approval = store.get_approval(approval_id)
        if not approval:
            raise HTTPException(status_code=404, detail="approval_not_found")
        return approval

    @app.post("/mobile/v1/approvals/{approval_id}/approve")
    def approve(approval_id: str, decision: ApprovalDecision, device_id: str = Depends(require_device)) -> object:
        approval = store.resolve_approval(approval_id, ApprovalStatus.approved)
        if not approval:
            raise HTTPException(status_code=404, detail="approval_not_found")
        store.record_approval_audit(approval_id, device_id, ApprovalStatus.approved, decision.comment or decision.reason)
        return approval

    @app.post("/mobile/v1/approvals/{approval_id}/deny")
    def deny(approval_id: str, decision: ApprovalDecision, device_id: str = Depends(require_device)) -> object:
        approval = store.resolve_approval(approval_id, ApprovalStatus.denied)
        if not approval:
            raise HTTPException(status_code=404, detail="approval_not_found")
        store.record_approval_audit(approval_id, device_id, ApprovalStatus.denied, decision.comment or decision.reason)
        return approval

    @app.get("/mobile/v1/sessions")
    def list_sessions(device_id: str = Depends(require_device)) -> dict[str, object]:
        return {"sessions": store.list_sessions()}

    @app.get("/mobile/v1/artifacts")
    def list_artifacts(device_id: str = Depends(require_device)) -> dict[str, object]:
        return {"artifacts": store.list_artifacts()}

    @app.get("/mobile/v1/cron/jobs")
    def list_cron_jobs(device_id: str = Depends(require_device)) -> dict[str, object]:
        return {"jobs": store.list_cron_jobs()}

    @app.get("/mobile/v1/cron/jobs/{job_id}")
    def get_cron_job(job_id: str, device_id: str = Depends(require_device)) -> object:
        job = store.get_cron_job(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="cron_job_not_found")
        return job

    @app.post("/mobile/v1/sessions", response_model=GoalResponse)
    def create_session(request: GoalRequest, device_id: str = Depends(require_device)) -> GoalResponse:
        session, timeline = store.create_session_from_goal(request.goal)
        return GoalResponse(session=session, timeline=timeline)

    @app.post("/mobile/v1/sessions/{session_id}/goals", response_model=GoalResponse)
    def append_goal(session_id: str, request: GoalRequest, device_id: str = Depends(require_device)) -> GoalResponse:
        result = store.append_goal(session_id, request.goal)
        if not result:
            raise HTTPException(status_code=404, detail="session_not_found")
        session, timeline = result
        return GoalResponse(session=session, timeline=timeline)

    @app.get("/mobile/v1/sessions/{session_id}/timeline")
    def session_timeline(session_id: str, device_id: str = Depends(require_device)) -> object:
        timeline = store.get_timeline(session_id)
        if not timeline:
            raise HTTPException(status_code=404, detail="session_not_found")
        return timeline

    @app.websocket("/mobile/v1/events")
    async def events(websocket: WebSocket) -> None:
        await websocket.accept()
        session_id = websocket.query_params.get("session_id")
        await websocket.send_json(
            {
                "id": "evt_mock_approval_requested",
                "type": "approval.requested",
                "session_id": "sess_mock_contribution",
                "created_at": "2026-06-24T10:00:00Z",
                "payload": {"approval_id": "appr_mock_git_push"},
            }
        )
        if session_id:
            timeline = store.get_timeline(session_id)
            if timeline:
                await websocket.send_json(
                    {
                        "id": "evt_mock_session_started",
                        "type": "session.started",
                        "session_id": session_id,
                        "created_at": "2026-06-24T10:00:01Z",
                        "payload": {"timeline": timeline.model_dump(mode="json")},
                    }
                )
                await websocket.send_json(
                    {
                        "id": "evt_mock_session_updated",
                        "type": "session.updated",
                        "session_id": session_id,
                        "created_at": "2026-06-24T10:00:02Z",
                        "payload": {"timeline": timeline.model_dump(mode="json")},
                    }
                )
        await websocket.close()

    return app


app = create_app()
