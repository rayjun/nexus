from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from fastapi.testclient import TestClient

from backend_plugin.hermes_mobile.models import AgentRequest
from backend_plugin.hermes_mobile.real_store import StateDbMobileStore
from backend_plugin.hermes_mobile.server import create_app, create_default_store


def auth_headers(client: TestClient) -> dict[str, str]:
    start = client.post("/mobile/v1/pair/start").json()
    complete = client.post(
        "/mobile/v1/pair/complete",
        json={"code": start["code"], "device_name": "Ray's Android", "platform": "android"},
    ).json()
    return {"Authorization": f"Bearer {complete['device_token']}"}


def create_state_db(path: Path) -> None:
    con = sqlite3.connect(path)
    con.executescript(
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            user_id TEXT,
            model TEXT,
            model_config TEXT,
            system_prompt TEXT,
            parent_session_id TEXT,
            started_at REAL NOT NULL,
            ended_at REAL,
            end_reason TEXT,
            message_count INTEGER DEFAULT 0,
            tool_call_count INTEGER DEFAULT 0,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            billing_provider TEXT,
            billing_base_url TEXT,
            billing_mode TEXT,
            estimated_cost_usd REAL,
            actual_cost_usd REAL,
            cost_status TEXT,
            cost_source TEXT,
            pricing_version TEXT,
            title TEXT,
            api_call_count INTEGER DEFAULT 0,
            cwd TEXT,
            handoff_state TEXT,
            handoff_platform TEXT,
            handoff_error TEXT,
            rewind_count INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT,
            tool_call_id TEXT,
            tool_calls TEXT,
            tool_name TEXT,
            timestamp REAL NOT NULL,
            token_count INTEGER,
            finish_reason TEXT,
            reasoning TEXT,
            reasoning_content TEXT,
            reasoning_details TEXT,
            codex_reasoning_items TEXT,
            codex_message_items TEXT,
            platform_message_id TEXT,
            observed INTEGER DEFAULT 0,
            active INTEGER NOT NULL DEFAULT 1,
            compacted INTEGER NOT NULL DEFAULT 0
        );
        """
    )
    con.execute(
        """
        INSERT INTO sessions(id, source, user_id, model, started_at, ended_at, title, message_count, tool_call_count, cwd)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        ("sess_real", "telegram", "ray", "gpt-5.5", 1_800_000_000.0, None, "Ship mobile adapter", 3, 1, "/repo"),
    )
    con.execute(
        "INSERT INTO messages(session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
        ("sess_real", "user", "Continue mobile adapter", 1_800_000_001.0),
    )
    con.execute(
        "INSERT INTO messages(session_id, role, content, tool_calls, timestamp) VALUES (?, ?, ?, ?, ?)",
        (
            "sess_real",
            "assistant",
            "I will inspect the project.",
            json.dumps(
                [
                    {
                        "id": "call_read",
                        "function": {"name": "read_file", "arguments": "{}"},
                    }
                ]
            ),
            1_800_000_002.0,
        ),
    )
    con.execute(
        "INSERT INTO messages(session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
        ("sess_real", "assistant", "Done. The adapter is ready.", 1_800_000_003.0),
    )
    con.commit()
    con.close()


def test_state_db_store_lists_real_sessions(tmp_path: Path):
    db_path = tmp_path / "state.db"
    create_state_db(db_path)
    store = StateDbMobileStore(db_path)

    sessions = store.list_sessions()

    assert len(sessions) == 1
    assert sessions[0].id == "sess_real"
    assert sessions[0].title == "Ship mobile adapter"
    assert sessions[0].status == "running"


def test_state_db_store_maps_messages_to_execution_timeline(tmp_path: Path):
    db_path = tmp_path / "state.db"
    create_state_db(db_path)
    store = StateDbMobileStore(db_path)

    timeline = store.get_timeline("sess_real")

    assert timeline is not None
    assert timeline.session_id == "sess_real"
    assert [item.type for item in timeline.items] == ["user_goal", "thinking_block", "assistant_result"]
    assert timeline.items[0].text == "Continue mobile adapter"
    assert timeline.items[1].tool_calls[0].name == "read_file"
    assert timeline.items[2].markdown == "Done. The adapter is ready."


def test_sessions_endpoint_can_use_real_state_store(tmp_path: Path):
    db_path = tmp_path / "state.db"
    create_state_db(db_path)
    store = StateDbMobileStore(db_path)
    client = TestClient(create_app(store=store))

    response = client.get("/mobile/v1/sessions", headers=auth_headers(client))

    assert response.status_code == 200
    body = response.json()
    assert body["sessions"][0]["id"] == "sess_real"
    assert body["sessions"][0]["status"] == "running"


def test_state_db_store_appends_goal_to_existing_session(tmp_path: Path, monkeypatch):
    db_path = tmp_path / "state.db"
    create_state_db(db_path)
    store = StateDbMobileStore(db_path)
    monkeypatch.setattr(store, "_read_api_key", lambda: "")

    session, timeline = store.append_goal("sess_real", "Continue from mobile")

    assert session.id == "sess_real"
    assert session.status == "running"
    assert timeline.items[-1].type == "user_goal"
    assert timeline.items[-1].text == "Continue from mobile"

    con = sqlite3.connect(db_path)
    row = con.execute(
        "SELECT role, content, active FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT 1",
        ("sess_real",),
    ).fetchone()
    count = con.execute("SELECT message_count FROM sessions WHERE id = ?", ("sess_real",)).fetchone()[0]
    con.close()
    assert row == ("user", "Continue from mobile", 1)
    assert count == 4


def test_append_goal_endpoint_returns_updated_timeline(tmp_path: Path, monkeypatch):
    db_path = tmp_path / "state.db"
    create_state_db(db_path)
    store = StateDbMobileStore(db_path)
    monkeypatch.setattr(store, "_read_api_key", lambda: "")
    client = TestClient(create_app(store=store))

    response = client.post(
        "/mobile/v1/sessions/sess_real/goals",
        headers=auth_headers(client),
        json={"goal": "Continue from mobile"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["session"]["id"] == "sess_real"
    assert body["timeline"]["items"][-1]["text"] == "Continue from mobile"


def test_state_db_store_persists_managed_agents(tmp_path: Path):
    db_path = tmp_path / "state.db"
    agents_path = tmp_path / "agents.json"
    create_state_db(db_path)
    first = StateDbMobileStore(db_path, agents_path=agents_path)

    agent = first.add_agent(AgentRequest(name="Lab Hermes", base_url="http://lab.local:8765"))

    import socket
    expected_name = socket.gethostname()
    second = StateDbMobileStore(db_path, agents_path=agents_path)
    assert [item.name for item in second.list_agents()] == [expected_name, "Lab Hermes"]
    assert second.remove_agent(agent.id) is True

    third = StateDbMobileStore(db_path, agents_path=agents_path)
    assert [item.name for item in third.list_agents()] == [expected_name]


def test_server_default_store_can_use_state_db_env(tmp_path: Path, monkeypatch):
    db_path = tmp_path / "state.db"
    create_state_db(db_path)
    monkeypatch.setenv("HERMES_MOBILE_STATE_DB", str(db_path))

    store = create_default_store()

    assert isinstance(store, StateDbMobileStore)
    assert store.list_sessions()[0].id == "sess_real"
