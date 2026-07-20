from __future__ import annotations

import threading
import sys
from types import ModuleType

from backend_plugin.hermes_mobile.live_approvals import HermesApprovalBridge, LiveApprovalMobileStore
from backend_plugin.hermes_mobile.models import ApprovalStatus
from backend_plugin.hermes_mobile.server import create_default_store
from backend_plugin.hermes_mobile.storage import MockMobileStore
from backend_plugin.hermes_mobile.real_store import StateDbMobileStore


class FakeApprovalEntry:
    def __init__(self, data: dict):
        self.data = data
        self.event = threading.Event()
        self.result = None


class FakeHermesApprovalModule:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._gateway_queues = {
            "telegram:503058709": [
                FakeApprovalEntry(
                    {
                        "command": "git push origin main",
                        "description": "pushes code to remote repository",
                        "pattern_key": "git_push",
                        "pattern_keys": ["git_push"],
                        "allow_permanent": True,
                    }
                )
            ]
        }
        self.resolved = []

    def resolve_gateway_approval(self, session_key: str, choice: str, resolve_all: bool = False) -> int:
        self.resolved.append((session_key, choice, resolve_all))
        queue = self._gateway_queues.get(session_key)
        if not queue:
            return 0
        entry = queue.pop(0)
        entry.result = choice
        entry.event.set()
        if not queue:
            self._gateway_queues.pop(session_key, None)
        return 1


def test_live_approval_bridge_lists_oldest_blocking_gateway_approval():
    bridge = HermesApprovalBridge(FakeHermesApprovalModule())

    approvals = bridge.list_approvals(status="pending")

    assert len(approvals) == 1
    approval = approvals[0]
    assert approval.id.startswith("live_approval_")
    assert approval.session_id == "telegram:503058709"
    assert approval.kind == "terminal_command"
    assert approval.risk == "high"
    assert approval.status == ApprovalStatus.pending
    assert approval.title == "Approve terminal command"
    assert approval.details["command"] == "git push origin main"
    assert approval.details["pattern_keys"] == ["git_push"]


def test_live_approval_bridge_resolves_approval_once_or_denied():
    module = FakeHermesApprovalModule()
    bridge = HermesApprovalBridge(module)
    approval_id = bridge.list_approvals(status="pending")[0].id

    approved = bridge.resolve_approval(approval_id, ApprovalStatus.approved)

    assert approved is not None
    assert approved.status == ApprovalStatus.approved
    assert module.resolved == [("telegram:503058709", "once", False)]
    assert bridge.list_approvals(status="pending") == []


def test_live_approval_store_combines_base_mock_and_live_approvals():
    module = FakeHermesApprovalModule()
    store = LiveApprovalMobileStore(MockMobileStore(), HermesApprovalBridge(module))

    approvals = store.list_approvals(status="pending")

    ids = {approval.id for approval in approvals}
    assert "appr_mock_git_push" in ids
    assert any(approval_id.startswith("live_approval_") for approval_id in ids)


def test_live_approval_store_resolves_live_approval_before_base_store():
    module = FakeHermesApprovalModule()
    store = LiveApprovalMobileStore(MockMobileStore(), HermesApprovalBridge(module))
    approval_id = [approval.id for approval in store.list_approvals(status="pending") if approval.id.startswith("live_approval_")][0]

    resolved = store.resolve_approval(approval_id, ApprovalStatus.denied)

    assert resolved is not None
    assert resolved.status == ApprovalStatus.denied
    assert module.resolved == [("telegram:503058709", "deny", False)]


def test_default_store_enables_live_approval_bridge_when_flag_is_set(monkeypatch):
    module = ModuleType("tools.approval")
    fake = FakeHermesApprovalModule()
    setattr(module, "_lock", fake._lock)
    setattr(module, "_gateway_queues", fake._gateway_queues)
    setattr(module, "resolve_gateway_approval", fake.resolve_gateway_approval)
    package = ModuleType("tools")
    monkeypatch.setitem(sys.modules, "tools", package)
    monkeypatch.setitem(sys.modules, "tools.approval", module)

    # LiveApprovalMobileStore is now default for StateDbMobileStore
    # Use a temp state.db to get StateDbMobileStore as base
    import tempfile, sqlite3
    from pathlib import Path
    tmp = Path(tempfile.mkdtemp()) / "state.db"
    con = sqlite3.connect(tmp)
    con.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, title TEXT, started_at REAL, ended_at REAL, end_reason TEXT, message_count INTEGER DEFAULT 0, archived INTEGER DEFAULT 0)")
    con.execute("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, timestamp REAL, active INTEGER DEFAULT 1, compacted INTEGER DEFAULT 0)")
    con.commit()
    con.close()
    monkeypatch.setenv("HERMES_MOBILE_STATE_DB", str(tmp))

    store = create_default_store()

    approvals = store.list_approvals(status="pending")
    assert any(approval.id.startswith("live_approval_") for approval in approvals)
