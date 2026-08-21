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
        .task {
            await ensureActiveServer()
            await loadOrCreateSession()
            await loadHistory()
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
                AttachPanel()
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
        var server = relay.servers.first { $0.id == resolvedBot.serverID }
        if server == nil, !relay.servers.isEmpty { server = relay.servers.first }
        guard let server else { errorText = "No server available"; return }
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
            if let dict = res as? [String: Any], let items = dict["items"] as? [[String: Any]] {
                let decoded = decodeTimeline(items)
                store.setMessages(decoded, for: resolvedBot.id)
            }
        } catch {
            os_log("history failed: %@", log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Send / interrupt

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        await ensureActiveServer()
        guard relay.isConnected else { errorText = "Not connected"; return }
        input = ""
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
            try? await Task.sleep(nanoseconds: 600_000_000)
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

    private func decodeTimeline(_ items: [[String: Any]]) -> [TimelineItem] {
        items.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return TimelineItem(
                id: id,
                type: (d["type"] as? String) ?? "assistant",
                text: d["text"] as? String,
                markdown: d["markdown"] as? String,
                title: d["title"] as? String,
                timestamp: (d["timestamp"] as? String) ?? "",
                toolName: d["tool_name"] as? String,
                toolCalls: d["tool_calls"] as? String
            )
        }
    }
}