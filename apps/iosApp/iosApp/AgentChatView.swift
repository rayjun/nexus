import SwiftUI

struct AgentChatView: View {
    var agent: NexusAgent
    @ObservedObject var registry: AgentRegistry
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var relay: RelayClient
    @State private var input = ""
    @State private var isSending = false
    @State private var isLoadingHistory = false
    @State private var errorText = ""
    @FocusState private var inputFocused: Bool

    private var resolvedAgent: NexusAgent {
        registry.agents.first(where: { $0.id == agent.id }) ?? agent
    }

    private var boundID: String? { resolvedAgent.boundSessionID }

    private var messages: [TimelineItem] { registry.messages(for: resolvedAgent.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(NexusStyle.border)
            if isLoadingHistory {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: resolvedAgent.icon).font(.system(size: 36)).foregroundStyle(NexusStyle.subtleText)
                    Text("Start chatting with \(resolvedAgent.displayName)").font(.system(size: 14)).foregroundStyle(NexusStyle.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { item in timelineRow(item) }
                        }.padding(16)
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if !errorText.isEmpty {
                Text(errorText).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 16).padding(.vertical, 6)
            }
            composer
        }
        .background(NexusStyle.background)
        .navigationBarHidden(true)
        .onAppear { Task { await ensureActiveServer(); await loadHistory() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(NexusStyle.blue) }
            Image(systemName: resolvedAgent.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(NexusStyle.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedAgent.displayName).font(.system(size: 16, weight: .semibold)).foregroundStyle(NexusStyle.text)
                Text(boundID ?? "New thread").font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusStyle.muted).lineLimit(1)
            }
            Spacer()
            if isSending {
                Button { Task { await interrupt() } } label: { Text("Stop").font(.system(size: 13, weight: .semibold)).foregroundStyle(.red) }
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(NexusStyle.muted) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NexusStyle.card)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message \(resolvedAgent.displayName)…", text: $input, axis: .vertical)
                .font(.system(size: 15)).lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                .focused($inputFocused)
                .onSubmit { Task { await send() } }
            Button { Task { await send() } } label: {
                if isSending { ProgressView().tint(.white).frame(width: 36, height: 36) }
                else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(canSend ? NexusStyle.blue : NexusStyle.subtleText) }
            }.disabled(!canSend || isSending)
        }
        .padding(12)
        .background(NexusStyle.card)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func timelineRow(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.type.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(NexusStyle.muted)
                Text(item.timestamp).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusStyle.subtleText)
                if let tool = item.toolName, !tool.isEmpty {
                    Text(tool).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(NexusStyle.blue)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(NexusStyle.blue.opacity(0.1), in: Capsule())
                }
                Spacer()
            }
            if let md = item.markdown, !md.isEmpty {
                Text(md).font(.system(size: 14)).foregroundStyle(NexusStyle.text).textSelection(.enabled)
            } else if let t = item.text, !t.isEmpty {
                Text(t).font(.system(size: 14)).foregroundStyle(NexusStyle.text).textSelection(.enabled)
            } else if let title = item.title, !title.isEmpty {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(NexusStyle.text)
            }
            if let calls = item.toolCalls, !calls.isEmpty {
                Text(calls).font(.system(size: 12, design: .monospaced)).foregroundStyle(NexusStyle.muted)
                    .padding(8).background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .background(item.type == "user" ? NexusStyle.selected.opacity(0.5) : NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
    }

    private func ensureActiveServer() async {
        if relay.activeServerID != resolvedAgent.serverID {
            relay.setActive(serverID: resolvedAgent.serverID)
        }
        if !relay.isConnected {
            // Poll briefly for the async connect to settle; then allow the call to fail gracefully.
            for _ in 0..<20 {
                if relay.isConnected { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func loadHistory() async {
        guard let sid = boundID, !sid.isEmpty else { return }
        await ensureActiveServer()
        guard relay.isConnected else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let res = try await relay.call("session.history", params: ["session_id": sid])
            if let dict = res as? [String: Any], let items = dict["items"] as? [[String: Any]] {
                let decoded = decodeTimeline(items)
                await MainActor.run { registry.setMessages(decoded, for: resolvedAgent.id) }
            }
        } catch { await MainActor.run { errorText = error.localizedDescription } }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        // Guard BEFORE any await so a second tap cannot pass the check while the
        // first send is still establishing a connection.
        isSending = true
        defer { isSending = false }
        await ensureActiveServer()
        guard relay.isConnected else { errorText = "Not connected"; return }
        input = ""
        errorText = ""
        do {
            // New thread → session.create first (prompt.submit with "new" is not resolvable server-side).
            // Gateway contract (methods_session.py): create returns {session_id (live), stored_session_id (persisted)};
            // prompt.submit then resolves the 8-hex sid. We bind the live sid so subsequent resume/history/interrupt work.
            var sid = boundID
            if sid == nil || sid!.isEmpty {
                let createRes = try await relay.call("session.create", params: ["title": agent.displayName])
                let created = SessionIDExtractor.extract(from: createRes)
                guard let created, !created.isEmpty else {
                    errorText = "Failed to create session"
                    isSending = false
                    return
                }
                await MainActor.run { registry.bindSession(agentID: resolvedAgent.id, sessionID: created) }
                sid = created
            }
            guard let sid, !sid.isEmpty else {
                errorText = "No active session"
                return
            }
            let res = try await relay.call("prompt.submit", params: ["session_id": sid, "text": text])
            if boundID == nil, let nid = SessionIDExtractor.extract(from: res), !nid.isEmpty {
                await MainActor.run { registry.bindSession(agentID: resolvedAgent.id, sessionID: nid) }
            }
            // Update the card preview immediately (fast feedback without waiting on history).
            await MainActor.run { registry.setPreview(for: resolvedAgent.id, preview: text) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await loadHistory()
        } catch { await MainActor.run { errorText = error.localizedDescription } }
    }

    private func interrupt() async {
        guard let sid = boundID, !sid.isEmpty else { return }
        _ = try? await relay.call("session.interrupt", params: ["session_id": sid])
        await loadHistory()
    }


    private func decodeTimeline(_ items: [[String: Any]]) -> [TimelineItem] {
        items.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return TimelineItem(id: id, type: (d["type"] as? String) ?? "assistant", text: d["text"] as? String, markdown: d["markdown"] as? String, title: d["title"] as? String, timestamp: (d["timestamp"] as? String) ?? "", toolName: d["tool_name"] as? String, toolCalls: d["tool_calls"] as? String)
        }
    }
}
