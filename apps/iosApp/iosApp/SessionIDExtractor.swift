import Foundation

/// Extract a usable session id from a Hermes gateway result dict.
///
/// Verified contract (hermes tui_gateway methods_session.py / methods_prompt.py):
/// - `session.create`  -> `{session_id: <8-hex live sid>, stored_session_id: <persisted key>}`
/// - `session.resume`  -> payload carrying the live sid (top-level or `info`)
/// - `prompt.submit`   -> `{"status":"streaming"}` — NO session id (returns nil)
///
/// Live sid is preferred because prompt.submit/history/resume/interrupt resolve
/// `session_id` against the gateway's live `_sessions` map.
enum SessionIDExtractor {
    static func extract(from value: Any) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let d = value as? [String: Any] {
            for k in ["session_id", "id", "sessionId"] {
                if let v = d[k] as? String, !v.isEmpty { return v }
                if let nested = d[k] as? [String: Any], let v = nested["id"] as? String, !v.isEmpty { return v }
            }
            if let info = d["info"] as? [String: Any] {
                for k in ["session_id", "sid"] {
                    if let v = info[k] as? String, !v.isEmpty { return v }
                }
            }
            if let data = d["data"] as? [String: Any] {
                for k in ["session_id", "id"] {
                    if let v = data[k] as? String, !v.isEmpty { return v }
                }
            }
        }
        return nil
    }
}
