import hashlib
import hmac
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient

from backend_plugin.hermes_mobile.server import create_app
from backend_plugin.hermes_mobile.storage import MockMobileStore


def auth_headers(client: TestClient) -> dict[str, str]:
    start = client.post("/mobile/v1/pair/start").json()
    complete = client.post(
        "/mobile/v1/pair/complete",
        json={"code": start["code"], "device_name": "Ray's Android", "platform": "android"},
    ).json()
    return {"Authorization": f"Bearer {complete['device_token']}"}


def paired_device(client: TestClient) -> dict[str, str]:
    start = client.post("/mobile/v1/pair/start").json()
    complete = client.post(
        "/mobile/v1/pair/complete",
        json={"code": start["code"], "device_name": "Ray's Android", "platform": "android"},
    ).json()
    return {"device_id": complete["device_id"], "device_token": complete["device_token"]}


def signed_auth_headers(
    device_id: str,
    device_token: str,
    method: str,
    target: str,
    timestamp: str | None = None,
    nonce: str = "nonce-test",
) -> dict[str, str]:
    timestamp = timestamp or datetime.now(UTC).isoformat().replace("+00:00", "Z")
    message = f"{method.upper()}\n{target}\n{timestamp}\n{nonce}"
    signature = hmac.new(device_token.encode(), message.encode(), hashlib.sha256).hexdigest()
    return {
        "Authorization": (
            f'HermesDevice device_id="{device_id}", '
            f'timestamp="{timestamp}", '
            f'nonce="{nonce}", '
            f'signature="{signature}"'
        )
    }


def test_status_endpoint_reports_mobile_api_capabilities():
    client = TestClient(create_app())

    response = client.get("/mobile/v1/status")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "online"
    assert body["gateway_ready"] is True
    assert body["api_version"] == "1.0"
    assert body["features"]["approvals"] is True
    assert body["features"]["session_timeline"] is True


def test_pair_start_returns_short_lived_pairing_code():
    client = TestClient(create_app())

    response = client.post("/mobile/v1/pair/start")

    assert response.status_code == 200
    body = response.json()
    assert body["pairing_id"].startswith("pair_")
    assert len(body["code"]) == 6
    assert body["code"].isdigit()
    assert body["expires_at"]
    assert body["qr_payload"].startswith("hermes://pair?")


def test_pair_start_generates_unique_pairing_codes():
    client = TestClient(create_app())

    codes = {client.post("/mobile/v1/pair/start").json()["code"] for _ in range(5)}

    assert len(codes) == 5


def test_pair_complete_rejects_unknown_pairing_code():
    client = TestClient(create_app())

    response = client.post(
        "/mobile/v1/pair/complete",
        json={"code": "000000", "device_name": "Ray's Android", "platform": "android"},
    )

    assert response.status_code == 404
    assert response.json()["detail"] == "pairing_code_not_found"


def test_pair_complete_rejects_expired_pairing_code():
    store = MockMobileStore()
    client = TestClient(create_app(store))
    start = client.post("/mobile/v1/pair/start").json()
    store.pending_pairings[start["code"]].expires_at = datetime.now(UTC) - timedelta(seconds=1)

    response = client.post(
        "/mobile/v1/pair/complete",
        json={"code": start["code"], "device_name": "Ray's Android", "platform": "android"},
    )

    assert response.status_code == 410
    assert response.json()["detail"] == "pairing_code_expired"


def test_pair_complete_exchanges_code_for_device_token_once():
    client = TestClient(create_app())
    start = client.post("/mobile/v1/pair/start").json()

    response = client.post(
        "/mobile/v1/pair/complete",
        json={
            "code": start["code"],
            "device_name": "Ray's Android",
            "platform": "android",
            "public_key": "test-public-key",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["device_id"].startswith("dev_")
    assert body["device_token"].startswith("hmob_")
    assert body["capabilities"]["approvals"] is True
    assert body["capabilities"]["sessions"] is True

    reused = client.post(
        "/mobile/v1/pair/complete",
        json={
            "code": start["code"],
            "device_name": "Ray's Android",
            "platform": "android",
        },
    )
    assert reused.status_code == 404
    assert reused.json()["detail"] == "pairing_code_not_found"


def test_resource_endpoints_require_valid_bearer_token():
    client = TestClient(create_app())

    missing = client.get("/mobile/v1/approvals?status=pending")
    invalid = client.get("/mobile/v1/approvals?status=pending", headers={"Authorization": "Bearer hmob_invalid"})

    assert missing.status_code == 401
    assert missing.json()["detail"] == "mobile_auth_required"
    assert invalid.status_code == 401
    assert invalid.json()["detail"] == "mobile_auth_required"


def test_resource_endpoints_accept_hermes_device_signed_auth():
    client = TestClient(create_app())
    device = paired_device(client)
    target = "/mobile/v1/approvals?status=pending"

    response = client.get(
        target,
        headers=signed_auth_headers(device["device_id"], device["device_token"], "GET", target),
    )

    assert response.status_code == 200
    assert response.json()["approvals"][0]["id"] == "appr_mock_git_push"


def test_signed_auth_rejects_stale_timestamp():
    client = TestClient(create_app())
    device = paired_device(client)
    target = "/mobile/v1/approvals?status=pending"
    stale = (datetime.now(UTC) - timedelta(minutes=10)).isoformat().replace("+00:00", "Z")

    response = client.get(
        target,
        headers=signed_auth_headers(device["device_id"], device["device_token"], "GET", target, timestamp=stale),
    )

    assert response.status_code == 401
    assert response.json()["detail"] == "mobile_auth_required"


def test_signed_auth_rejects_nonce_replay():
    client = TestClient(create_app())
    device = paired_device(client)
    target = "/mobile/v1/approvals?status=pending"
    headers = signed_auth_headers(device["device_id"], device["device_token"], "GET", target, nonce="nonce-replay")

    first = client.get(target, headers=headers)
    replay = client.get(target, headers=headers)

    assert first.status_code == 200
    assert replay.status_code == 401
    assert replay.json()["detail"] == "mobile_auth_required"


def test_approve_endpoint_records_mobile_audit_entry():
    store = MockMobileStore()
    client = TestClient(create_app(store))
    headers = auth_headers(client)

    response = client.post(
        "/mobile/v1/approvals/appr_mock_git_push/approve",
        json={"comment": "Looks good", "biometric_verified": False},
        headers=headers,
    )

    assert response.status_code == 200
    assert len(store.approval_audit_log) == 1
    audit = store.approval_audit_log[0]
    assert audit.approval_id == "appr_mock_git_push"
    assert audit.device_id.startswith("dev_")
    assert audit.decision == "approved"
    assert audit.comment == "Looks good"


def test_devices_endpoint_lists_paired_devices_without_tokens():
    client = TestClient(create_app())
    headers = auth_headers(client)

    response = client.get("/mobile/v1/devices", headers=headers)

    assert response.status_code == 200
    devices = response.json()["devices"]
    assert len(devices) == 1
    assert devices[0]["id"].startswith("dev_")
    assert devices[0]["name"] == "Ray's Android"
    assert devices[0]["platform"] == "android"
    assert "device_token" not in devices[0]


def test_agents_endpoint_can_add_and_remove_managed_agents():
    client = TestClient(create_app())
    headers = auth_headers(client)

    initial = client.get("/mobile/v1/agents", headers=headers)
    assert initial.status_code == 200
    assert initial.json()["agents"][0]["name"] == "Local Hermes"

    created = client.post(
        "/mobile/v1/agents",
        headers=headers,
        json={"name": "Local Hermes", "base_url": "http://127.0.0.1:8766"},
    )
    assert created.status_code == 200
    body = created.json()
    assert body["name"] == "Local Hermes"
    assert body["status"] == "offline"

    listed = client.get("/mobile/v1/agents", headers=headers).json()["agents"]
    assert [agent["name"] for agent in listed] == ["Local Hermes", "Local Hermes"]

    deleted = client.delete(f"/mobile/v1/agents/{body['id']}", headers=headers)
    assert deleted.status_code == 204
    listed_after_delete = client.get("/mobile/v1/agents", headers=headers).json()["agents"]
    assert [agent["name"] for agent in listed_after_delete] == ["Local Hermes"]


def test_revoke_device_invalidates_its_bearer_token():
    client = TestClient(create_app())
    headers = auth_headers(client)
    device_id = client.get("/mobile/v1/devices", headers=headers).json()["devices"][0]["id"]

    revoke = client.delete(f"/mobile/v1/devices/{device_id}", headers=headers)
    after = client.get("/mobile/v1/approvals?status=pending", headers=headers)

    assert revoke.status_code == 204
    assert after.status_code == 401
    assert after.json()["detail"] == "mobile_auth_required"


def test_revoke_unknown_device_returns_404():
    client = TestClient(create_app())
    headers = auth_headers(client)

    response = client.delete("/mobile/v1/devices/dev_missing", headers=headers)

    assert response.status_code == 404
    assert response.json()["detail"] == "device_not_found"


def test_pending_approvals_endpoint_returns_structured_approval():
    client = TestClient(create_app())

    response = client.get("/mobile/v1/approvals?status=pending", headers=auth_headers(client))

    assert response.status_code == 200
    approvals = response.json()["approvals"]
    assert len(approvals) == 1
    approval = approvals[0]
    assert approval["id"] == "appr_mock_git_push"
    assert approval["kind"] == "terminal_command"
    assert approval["risk"] == "high"
    assert approval["status"] == "pending"
    assert approval["details"]["repo"] == "user/hermes-agent"


def test_approve_endpoint_resolves_pending_approval():
    client = TestClient(create_app())

    response = client.post(
        "/mobile/v1/approvals/appr_mock_git_push/approve",
        json={"comment": "Looks good", "biometric_verified": False},
        headers=auth_headers(client),
    )

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == "appr_mock_git_push"
    assert body["status"] == "approved"


def test_create_session_from_goal_returns_structured_timeline():
    client = TestClient(create_app())

    response = client.post(
        "/mobile/v1/sessions",
        json={"goal": "Summarize pending approvals and suggest next action"},
        headers=auth_headers(client),
    )

    assert response.status_code == 200
    body = response.json()
    assert body["session"]["id"].startswith("sess_goal_")
    assert body["session"]["title"] == "Summarize pending approvals and suggest next action"
    assert body["timeline"]["session_id"] == body["session"]["id"]
    assert body["timeline"]["items"][0]["type"] == "user_goal"
    assert body["timeline"]["items"][0]["text"] == "Summarize pending approvals and suggest next action"


def test_append_goal_to_existing_session_adds_execution_log_item():
    client = TestClient(create_app())

    response = client.post(
        "/mobile/v1/sessions/sess_mock_contribution/goals",
        json={"goal": "Continue with the safest next step"},
        headers=auth_headers(client),
    )

    assert response.status_code == 200
    body = response.json()
    assert body["timeline"]["session_id"] == "sess_mock_contribution"
    assert body["timeline"]["items"][-1]["type"] == "thinking_block"
    assert body["timeline"]["items"][-2]["text"] == "Continue with the safest next step"


def test_session_timeline_returns_execution_log_not_chat_bubbles():
    client = TestClient(create_app())

    response = client.get("/mobile/v1/sessions/sess_mock_contribution/timeline", headers=auth_headers(client))

    assert response.status_code == 200
    body = response.json()
    assert body["session_id"] == "sess_mock_contribution"
    item_types = [item["type"] for item in body["items"]]
    assert item_types == ["user_goal", "thinking_block", "assistant_result"]
    thinking = body["items"][1]
    assert thinking["title"] == "Thinking"
    assert thinking["tool_calls"][0]["status"] == "completed"


def test_artifacts_endpoint_returns_session_outputs():
    client = TestClient(create_app())

    response = client.get("/mobile/v1/artifacts", headers=auth_headers(client))

    assert response.status_code == 200
    artifacts = response.json()["artifacts"]
    assert len(artifacts) == 2
    assert artifacts[0]["id"] == "art_mock_patch"
    assert artifacts[0]["session_id"] == "sess_mock_contribution"
    assert artifacts[0]["kind"] == "file"
    assert artifacts[0]["title"] == "mobile-api.patch"
    assert artifacts[0]["metadata"]["language"] == "diff"


def test_cron_jobs_endpoint_returns_read_only_automations():
    client = TestClient(create_app())

    response = client.get("/mobile/v1/cron/jobs", headers=auth_headers(client))

    assert response.status_code == 200
    jobs = response.json()["jobs"]
    assert len(jobs) == 2
    assert jobs[0]["id"] == "cron_mock_morning_report"
    assert jobs[0]["name"] == "DeFi morning report"
    assert jobs[0]["enabled"] is True
    assert jobs[0]["last_run"]["status"] == "success"


def test_cron_job_detail_endpoint_returns_single_automation():
    client = TestClient(create_app())

    response = client.get("/mobile/v1/cron/jobs/cron_mock_morning_report", headers=auth_headers(client))

    assert response.status_code == 200
    job = response.json()
    assert job["id"] == "cron_mock_morning_report"
    assert job["name"] == "DeFi morning report"
    assert job["schedule"] == "0 9 * * *"
    assert job["last_run"]["summary"] == "Delivered concise DeFi morning report."


def test_cron_job_detail_endpoint_returns_404_for_unknown_job():
    client = TestClient(create_app())

    response = client.get("/mobile/v1/cron/jobs/missing", headers=auth_headers(client))

    assert response.status_code == 404
    assert response.json()["detail"] == "cron_job_not_found"


def test_events_websocket_emits_structured_approval_event():
    client = TestClient(create_app())
    with client.websocket_connect("/mobile/v1/events") as websocket:
        event = websocket.receive_json()

    assert event["type"] == "approval.requested"
    assert event["session_id"] == "sess_mock_contribution"
    assert event["payload"]["approval_id"] == "appr_mock_git_push"


def test_events_websocket_emits_session_timeline_updates():
    client = TestClient(create_app())
    with client.websocket_connect("/mobile/v1/events?session_id=sess_mock_contribution") as websocket:
        events = [websocket.receive_json(), websocket.receive_json(), websocket.receive_json()]

    assert [event["type"] for event in events] == [
        "approval.requested",
        "session.started",
        "session.updated",
    ]
    updated = events[-1]
    assert updated["session_id"] == "sess_mock_contribution"
    assert updated["payload"]["timeline"]["items"][-1]["type"] == "assistant_result"
