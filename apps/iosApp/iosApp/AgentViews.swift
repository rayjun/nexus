import SwiftUI

struct AgentComposeView: View {
    @ObservedObject var registry: AgentRegistry
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var relay: RelayClient
    var onCreated: ((Agent) -> Void)? = nil

    @State private var name = ""
    @State private var icon = "sparkles"
    @State private var descriptionText = ""
    @State private var selectedServerID = ""
    @State private var mode: Mode = .newChat
    @State private var selectedSessionID = ""
    @State private var sessions: [SessionSummary] = []
    @State private var isLoadingSessions = false
    @State private var isSaving = false
    @State private var errorText = ""

    enum Mode: String, CaseIterable {
        case newChat
        case importSession
    }

    private let iconOptions = ["sparkles", "person.crop.circle", "brain.head.profile", "wand.and.stars", "cpu", "bolt.fill", "star.fill", "leaf.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $descriptionText)
                    Picker("Icon", selection: $icon) {
                        ForEach(iconOptions, id: \.self) { o in Label(o, systemImage: o).tag(o) }
                    }
                }
                Section("Server") {
                    Picker("Server", selection: $selectedServerID) {
                        Text("Select a server").tag("")
                        ForEach(relay.servers) { s in
                            Label(s.name, systemImage: s.isOnline ? "circle.fill" : "circle").tag(s.id)
                        }
                    }
                    if relay.servers.isEmpty {
                        Text("Pair a server first.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Thread") {
                    Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { m in Text(m.rawValue).tag(m) } }.pickerStyle(.segmented)
                    if mode == .newChat {
                        Text("A new thread will be created on first message.").font(.footnote).foregroundStyle(.secondary)
                        Text("Manual provisioning on the server is available in v2.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if isLoadingSessions { ProgressView() }
                        else if sessions.isEmpty {
                            Text("No sessions found on this server.").font(.footnote).foregroundStyle(.secondary)
                            Button("Reload") { Task { await loadSessions() } }
                            Text("You can switch to New chat.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Picker("Session", selection: $selectedSessionID) {
                                Text("Select a session").tag("")
                                ForEach(sessions) { s in Text(s.title.isEmpty ? s.id : s.title).tag(s.id) }
                            }
                        }
                    }
                }
                if !errorText.isEmpty {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Add Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(!canSave || isSaving)
                }
            }
            .disabled(isSaving)
        }
        .onAppear {
            if selectedServerID.isEmpty { selectedServerID = relay.activeServerID ?? relay.servers.first?.id ?? "" }
            if mode == .importSession { Task { await loadSessions() } }
        }
        .onChange(of: selectedServerID) { _ in if mode == .importSession { Task { await loadSessions() } } }
        .onChange(of: mode) { m in if m == .importSession { Task { await loadSessions() } } }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selectedServerID.isEmpty && (mode == .newChat || !selectedSessionID.isEmpty)
    }

    private func loadSessions() async {
        guard !selectedServerID.isEmpty else { return }
        if relay.activeServerID != selectedServerID { relay.setActive(serverID: selectedServerID) }
        if !relay.isConnected {
            for _ in 0..<20 {
                if relay.isConnected { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        guard relay.isConnected else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        if let res = try? await relay.call("session.list", params: [:]) {
            if let dict = res as? [String: Any], let arr = dict["sessions"] as? [[String: Any]] {
                sessions = arr.compactMap { d in
                    guard let id = d["id"] as? String else { return nil }
                    return SessionSummary(id: id, title: (d["title"] as? String) ?? "", preview: (d["preview"] as? String) ?? "", messageCount: (d["message_count"] as? Int) ?? 0, status: (d["status"] as? String) ?? "", createdAt: (d["created_at"] as? String) ?? "", updatedAt: (d["updated_at"] as? String) ?? "")
                }
            } else if let arr = res as? [[String: Any]] {
                sessions = arr.compactMap { d in
                    guard let id = d["id"] as? String else { return nil }
                    return SessionSummary(id: id, title: (d["title"] as? String) ?? "", preview: (d["preview"] as? String) ?? "", messageCount: (d["message_count"] as? Int) ?? 0, status: (d["status"] as? String) ?? "", createdAt: (d["created_at"] as? String) ?? "", updatedAt: (d["updated_at"] as? String) ?? "")
                }
            }
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { errorText = "Enter a name"; return }
        guard !selectedServerID.isEmpty else { errorText = "Pick a server"; return }
        if mode == .importSession && selectedSessionID.isEmpty { errorText = "Pick a session or switch to New chat"; return }
        isSaving = true
        defer { isSaving = false }
        // Import session → bind the LIVE sid. session.list returns the persisted
        // key; prompt.submit/history/interrupt resolve only against live _sessions
        // (verified contract, methods_session.py). session.resume resolves the key
        // through the compression-continuation chain to the live tip, then returns
        // a payload carrying the live sid — bind that, not the stored key.
        var bound: String? = nil
        if mode == .importSession {
            guard !selectedSessionID.isEmpty else { errorText = "Pick a session or switch to New chat"; return }
            if let resumeRes = try? await relay.call("session.resume", params: ["session_id": selectedSessionID]) {
                let live = extractSessionID(from: resumeRes)
                if let live, !live.isEmpty {
                    bound = live
                }
            }
            if bound == nil {
                errorText = "Could not open this session (already deleted or too large to resume)"
                return
            }
        }
        let agent = Agent(
            id: Agent.localID(),
            serverID: selectedServerID,
            boundSessionID: bound,
            name: trimmedName,
            icon: icon,
            description: descriptionText,
            status: .ready
        )
        await MainActor.run {
            registry.upsert(agent)
            dismiss()
            onCreated?(agent)
        }
    }

    /// Extract a usable session id from a gateway result dict (mirrors
    /// AgentChatView.extractSessionID). Prefers the live sid.
    private func extractSessionID(from value: Any) -> String? {
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
}

struct AgentDetailView: View {
    var agent: Agent
    @ObservedObject var registry: AgentRegistry
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var icon: String = "sparkles"
    @State private var desc: String = ""
    @State private var showDeleteConfirm = false

    private let iconOptions = ["sparkles", "person.crop.circle", "brain.head.profile", "wand.and.stars", "cpu", "bolt.fill", "star.fill", "leaf.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    TextField("Name", text: $name)
                    Picker("Icon", selection: $icon) { ForEach(iconOptions, id: \.self) { o in Label(o, systemImage: o).tag(o) } }
                    TextField("Description", text: $desc, axis: .vertical)
                }
                Section("Status") {
                    LabeledContent("ID", value: agent.id)
                    LabeledContent("Server", value: agent.serverID)
                    LabeledContent("Thread", value: agent.boundSessionID ?? "—")
                    LabeledContent("State", value: agent.status.rawValue)
                    if let e = agent.lastError, !e.isEmpty { Text(e).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button("Delete agent", role: .destructive) { showDeleteConfirm = true }
                } footer: { Text("Deletes the local registry entry and cached chat. The server session is not deleted.") }
                if agent.status == .lostKeys || agent.status == .offline {
                    Section { Text("Re-pair the server from the Home screen to restore this agent.") }
                }
            }
            .navigationTitle("Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .alert("Delete this agent?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { registry.remove(id: agent.id); dismiss() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { name = agent.name; icon = agent.icon; desc = agent.description }
    }

    private func save() {
        var updated = agent
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { updated.name = trimmed }
        updated.icon = icon
        updated.description = desc
        updated.updatedAt = Date()
        registry.upsert(updated)
        dismiss()
    }
}
