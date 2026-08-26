import SwiftUI
import os.log

/// Chat with a bot (a Hermes profile). Session resolution (T5 acceptance):
///   preferred (local nexus_preferred_v2, authoritative) ?? lastSessionID ??
///   session.create(profile:) → bind live sid; stale id → create-new fallback.
/// TG-style input bar: [📎][Message… 😊][🔼] — smiley INSIDE the field.
struct ChatView: View {
    let bot: Bot
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var relay: RelayClient

    @State private var input = ""
    @State private var isSending = false
    @State private var isLoadingHistory = false
    @State private var errorText = ""
    @State private var activeSessionID: String?
    @State private var panel: ChatPanel = .none
    @State private var stagedAttach: String?
    @FocusState private var inputFocused: Bool

    private let log = OSLog(subsystem: "com.rayjun.nexus", category: "ChatView")

    private var resolvedBot: Bot {
        store.bots.first(where: { $0.id == bot.id }) ?? bot
    }

    private var messages: [TimelineItem] { store.messages(for: resolvedBot.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(NexusStyle.border)
            if isLoadingHistory {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 34)).foregroundStyle(NexusStyle.subtleText)
                    Text("Start chatting with \(resolvedBot.displayTitle)")
                        .font(.system(size: 14)).foregroundStyle(NexusStyle.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { item in timelineRow(item) }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            inputBar
        }
        .background(NexusStyle.background)
        .navigationBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RelayEvent"))) { note in
            guard let event = note.userInfo?["event"] as? String,
                  let data = note.userInfo?["data"] as? [String: Any] else { return }
            handleLiveEvent(event, data)
        }
        .task {
            await ensureActiveServer()
            await loadOrCreateSession()
            await loadHistory()
        }
    }

    // MARK: - Live event handling (streaming)

    /// Consume message.start/delta/interim/complete forwarded by the relay
    /// agent for THIS bot's profile/session.
    private func handleLiveEvent(_ event: String, _ data: [String: Any]) {
        let sessionID = activeSessionID
        switch event {
        case "message.start":
            store.appendStream(botID: resolvedBot.id, sessionID: sessionID, text: "")
        case "message.delta", "message.interim":
            if let text = data["text"] as? String, !text.isEmpty {
                store.appendStream(botID: resolvedBot.id, sessionID: sessionID, text: text)
            }
        case "message.complete":
            if let text = data["text"] as? String {
                store.finishStream(botID: resolvedBot.id, sessionID: sessionID, finalText: text)
                if let sid = sessionID {
                    store.bindPreferredSession(botID: resolvedBot.id, sessionID: sid)
                }
                Task { await loadHistory() }
            }
        default:
            break
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NexusStyle.blue)
            }
            ZStack {
                Circle().fill(NexusStyle.blue).frame(width: 34, height: 34)
                Text(String(resolvedBot.displayTitle.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedBot.displayTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(NexusStyle.text)
                    .lineLimit(1)
                Text(resolvedBot.status == .offline ? "Offline" : "Online")
                    .font(.system(size: 11))
                    .foregroundStyle(resolvedBot.status == .offline ? NexusStyle.subtleText : NexusStyle.green)
            }
            Spacer()
            if isSending {
                Button {
                    Task { await interrupt() }
                } label: {
                    Text("Stop")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NexusStyle.muted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NexusStyle.card)
    }

    // MARK: - Input bar (T5a text+send; T5b emoji; T5c attach + commands)

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let staged = stagedAttach {
                HStack {
                    AttachChip(label: staged) { stagedAttach = nil }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
            if input.hasPrefix("/") {
                CommandSuggestCard(input: $input)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                Button {
                    togglePanel(.attach)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 19))
                        .foregroundStyle(panel == .attach ? NexusStyle.blue : NexusStyle.muted)
                }
                .buttonStyle(.plain)
                ZStack(alignment: .trailing) {
                    TextField("Message \(resolvedBot.displayTitle)…", text: $input, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(1...4)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .padding(.trailing, 36)
                        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                        .focused($inputFocused)
                        .onSubmit { Task { await send() } }
                        .onChange(of: input) { _ in
                            if input.hasPrefix("/") { panel = .none }
                        }
                    Button {
                        togglePanel(.emoji)
                        inputFocused = false
                    } label: {
                        Text("😊")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)
                }
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend && !isSending ? NexusStyle.blue : NexusStyle.subtleText)
                }
                .buttonStyle(.plain)
                .disabled(!canSend || isSending)
            }
            .padding(12)
            .background(NexusStyle.card)

            switch panel {
            case .none:
                EmptyView()
            case .emoji:
                EmojiPanel(input: $input)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .attach:
                AttachPanel { kind in
                    switch kind {
                    case .photo(let name):
                        stagedAttach = "📷 \(name)"
                    case .file(let name):
                        stagedAttach = "📎 \(name)"
                    case .camera:
                        stagedAttach = "📷 camera capture"
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: panel)
    }

    /// TG rule: swapping keyboard ↔ panel; panels are mutually exclusive and
    /// both keep the input bar visible.
    private func togglePanel(_ target: ChatPanel) {
        if panel == target {
            panel = .none
        } else {
            panel = target
        }
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Session resolution (T5 acceptance)

    private func ensureActiveServer() async {
        // Strict: the bot's own server must exist. Falling back to another
        // server would create sessions under this profile name on the WRONG
        // host (cross-server misrouting) — fail loudly instead.
        guard let server = relay.servers.first(where: { $0.id == resolvedBot.serverID }) else {
            errorText = "Server for \"\(resolvedBot.displayTitle)\" is gone — remove and re-add the bot"
            return
        }
        if relay.activeServerID != server.id {
            relay.setActive(serverID: server.id)
        }
        if !relay.isConnected {
            for _ in 0..<20 {
                if relay.isConnected { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// Resolve the live session id: local preferred (authoritative) → last
    /// session from roster → session.create + bind. Stale ids fall through to
    /// create-new rather than failing the chat.
    private func loadOrCreateSession() async {
        guard activeSessionID == nil else { return }
        let botID = resolvedBot.id

        func tryResume(_ sid: String) async -> String? {
            do {
                let res = try await relay.call(
                    serverID: resolvedBot.serverID,
                    method: "session.resume",
                    params: ["profile": resolvedBot.name, "session_id": sid]
                )
                if let live = SessionIDExtractor.extract(from: res) {
                    return live
                }
                return nil
            } catch {
                os_log("resume failed (stale): %@", log: log, type: .error, error.localizedDescription)
                return nil
            }
        }

        // Preferred first (local map is authoritative).
        if let preferred = store.preferredSessions[botID] {
            if let live = await tryResume(preferred) {
                activeSessionID = live
                return
            }
        }
        // Fall back to the roster's last session id.
        if let last = resolvedBot.lastSessionID {
            if let live = await tryResume(last) {
                activeSessionID = live
                return
            }
        }
        // No usable session — create a fresh one on this profile.
        do {
            let res = try await relay.call(
                serverID: resolvedBot.serverID,
                method: "session.create",
                params: ["profile": resolvedBot.name, "title": resolvedBot.displayTitle]
            )
            guard let sid = SessionIDExtractor.extract(from: res), !sid.isEmpty else {
                errorText = "Could not start a session with this bot"
                return
            }
            activeSessionID = sid
            store.bindPreferredSession(botID: botID, sessionID: sid)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadHistory() async {
        guard let sid = activeSessionID, !sid.isEmpty else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let res = try await relay.call(
                serverID: resolvedBot.serverID,
                method: "session.history",
                params: ["session_id": sid]
            )
            // Hermes returns {"count": N, "messages": [{role, text, timestamp?}]}
            // — NOT "items"; that key never existed (silent empty history).
            if let dict = res as? [String: Any], let items = dict["messages"] as? [[String: Any]] {
                let decoded = decodeTimeline(items)
                store.setMessages(decoded, for: resolvedBot.id)
            }
        } catch {
            os_log("history failed: %@", log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Send / interrupt

    private func send() async {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let staged = stagedAttach {
            // Staged attachment rides along as a text reference the bot can
            // open locally (no file-attach RPC on the low-trust allowlist).
            if text.isEmpty {
                text = "[\(staged)]"
            } else {
                text = "[\(staged)] \(text)"
            }
        }
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        await ensureActiveServer()
        guard relay.isConnected else { errorText = "Not connected"; return }
        input = ""
        stagedAttach = nil
        errorText = ""
        // Ensure session exists before submitting (prompt.submit is
        // streaming-only and cannot create; "new" is NOT resolvable).
        await loadOrCreateSession()
        guard let sid = activeSessionID else { errorText = "No active session"; return }
        do {
            _ = try await relay.call(
                serverID: resolvedBot.serverID,
                method: "prompt.submit",
                params: ["session_id": sid, "text": text]
            )
            store.setPreview(for: resolvedBot.id, preview: text)
            // Streaming owns the live reply (RelayEvent → appendStream). The
            // fallback reload keeps things consistent if events were missed
            // (e.g. reconnect mid-turn) — harmless duplicate refresh.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadHistory()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func interrupt() async {
        guard let sid = activeSessionID, !sid.isEmpty else { return }
        _ = try? await relay.call(
            serverID: resolvedBot.serverID,
            method: "session.interrupt",
            params: ["session_id": sid]
        )
        await loadHistory()
    }

    // MARK: - Timeline rendering

    private func timelineRow(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.type.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(NexusStyle.muted)
                Text(item.timestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NexusStyle.subtleText)
                if let tool = item.toolName, !tool.isEmpty {
                    Text(tool)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(NexusStyle.blue)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(NexusStyle.blue.opacity(0.1), in: Capsule())
                }
                Spacer()
            }
            if let md = item.markdown, !md.isEmpty {
                Text(md).font(.system(size: 14)).foregroundStyle(NexusStyle.text)
                    .textSelection(.enabled)
            } else if let t = item.text, !t.isEmpty {
                Text(t).font(.system(size: 14)).foregroundStyle(NexusStyle.text)
                    .textSelection(.enabled)
            } else if let title = item.title, !title.isEmpty {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(NexusStyle.text)
            }
        }
        .padding(12)
        .background(
            item.type == "user" ? NexusStyle.selected.opacity(0.5) : NexusStyle.row,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
    }

    /// Decode session.history messages: {role: user|assistant|tool, text,
    /// timestamp?: unix-sec}. id is synthesized (row_id when present, else
    /// index-stable) since history rows carry no client-facing id.
    private func decodeTimeline(_ items: [[String: Any]]) -> [TimelineItem] {
        items.enumerated().compactMap { idx, d in
            let role = (d["role"] as? String) ?? "assistant"
            let text = (d["text"] as? String) ?? ""
            guard !text.isEmpty else { return nil }
            let ts = d["timestamp"] as? Double ?? 0
            return TimelineItem(
                id: (d["row_id"] as? String) ?? "h\(idx)",
                type: role == "user" ? "user" : (role == "tool" ? "tool" : "assistant"),
                text: text,
                markdown: nil,
                title: (d["name"] as? String) ?? (role == "tool" ? "tool" : nil),
                timestamp: ts > 0 ? Self.hhmm(ts) : "",
                toolName: role == "tool" ? (d["name"] as? String) : nil,
                toolCalls: nil
            )
        }
    }

    private static func hhmm(_ unix: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: unix))
    }
}