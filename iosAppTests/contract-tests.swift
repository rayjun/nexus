#!/usr/bin/env swift
// Contract regression tests for the Nexus agent-centric session flow.
// Verifies the exact shapes returned by hermes tui_gateway (methods_session.py /
// methods_prompt.py) against our SessionIDExtractor — prompt.submit is
// streaming-only (no session id), session.create returns the live 8-hex sid,
// and imported sessions must be resolved via session.resume (persisted key →
// live sid). Run from repo root:  swift iosAppTests/contract-tests.swift
import Foundation

// ── Mirror of SessionIDExtractor (keeps this script self-contained: it must
//    run without building the app target). Any change to SessionIDExtractor
//    must be mirrored here; the app's own unit tests (when added via xcodegen)
//    will use @testable import to cover the real implementation.
func extract(from value: Any) -> String? {
    if let s = value as? String, !s.isEmpty { return s }
    if let d = value as? [String: Any] {
        for k in ["session_id", "id", "sessionId"] {
            if let v = d[k] as? String, !v.isEmpty { return v }
            if let nested = d[k] as? [String: Any], let v = nested["id"] as? String, !v.isEmpty { return v }
        }
        if let info = d["info"] as? [String: Any] {
            for k in ["session_id", "sid"] { if let v = info[k] as? String, !v.isEmpty { return v } }
        }
        if let data = d["data"] as? [String: Any] {
            for k in ["session_id", "id"] { if let v = data[k] as? String, !v.isEmpty { return v } }
        }
    }
    return nil
}

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

// 1) session.create -> {session_id: live, stored_session_id: key}; live wins.
let create: [String: Any] = ["session_id": "a1b2c3d4", "stored_session_id": "sess-key-xyz"]
expect(extract(from: create) == "a1b2c3d4", "session.create -> live sid")

// 2) CRITICAL: prompt.submit returns {"status":"streaming"} — no session id.
let streaming: [String: Any] = ["status": "streaming", "turn_isolation": true]
expect(extract(from: streaming) == nil, "prompt.submit streaming -> nil (no false bind)")

// 3) session.list row {id: persisted Key} — a STATIC binding to this is WRONG;
//    import must session.resume first.
let listRow: [String: Any] = ["id": "persisted-key", "title": "T", "preview": "P"]
let listId = extract(from: listRow)
expect(listId == "persisted-key", "session.list id extracted (import must resume it, not bind inline)")

// 4) session.resume -> carries live sid at top level.
let resume: [String: Any] = ["session_id": "deadbeef"]
expect(extract(from: resume) == "deadbeef", "session.resume -> live sid")

// 5) session.resume -> live sid via info.
let resumeInfo: [String: Any] = ["info": ["sid": "deadbeef", "model": "glm-5.2"]]
expect(extract(from: resumeInfo) == "deadbeef", "session.resume -> live sid via info")

// 6) bare string passthrough.
expect(extract(from: "abc123") == "abc123", "bare string passthrough")

print(failures == 0 ? "\nALL OK (6/6)" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
