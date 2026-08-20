import SwiftUI

struct AgentHomeView: View {
    @ObservedObject var registry: AgentRegistry
    @EnvironmentObject private var relay: RelayClient
    @State private var isShowingCompose = false
    @State private var isShowingSettings = false
    @State private var relayUrlDraft = ""
    @State private var selectedNexusAgent: NexusAgent?
    @State private var isShowingDetail = false
    @State private var detailNexusAgent: NexusAgent?
    @State private var toast: ToastMessage?
    @State private var approvalCount = 0
    @State private var isLoadingApprovals = false
    @Environment(\.scenePhase) private var scenePhase

    private var groupedAgents: [(ServerProfile?, [NexusAgent])] {
        var result: [(ServerProfile?, [NexusAgent])] = []
        let grouped = Dictionary(grouping: registry.agents, by: { $0.serverID })
        for server in relay.servers {
            if let list = grouped[server.id] { result.append((server, list)) }
        }
        if let orphans = grouped[""], !orphans.isEmpty { result.append((nil, orphans)) }
        let groupedIDs = Set(grouped.keys)
        for sid in groupedIDs where relay.servers.first(where: { $0.id == sid }) == nil && sid != "" {
            if let list = grouped[sid] { result.append((nil, list)) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        topBar
                        statusRow
                        approvalBadge
                        if registry.agents.isEmpty {
                            emptyState
                        } else {
                            agentList
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
                .refreshable { await refreshApprovals() }
                if let toast {
                    ToastView(message: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1000)
                        .onAppear {
                            Task {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                await MainActor.run { self.toast = nil }
                            }
                        }
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear { syncStatus(); Task { await refreshApprovals() } }
        .onChange(of: scenePhase) { phase in
            if phase == .active { syncStatus(); Task { await refreshApprovals() } }
        }
        .onChange(of: relay.isConnected) { connected in
            syncStatus()
            if connected { Task { await refreshApprovals() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RelayPairingFailed"))) { note in
            if let sid = note.object as? String, let msg = (note.userInfo?["message"] as? String) {
                registry.setLostKeys(for: sid, message: msg)
            }
        }
        .sheet(isPresented: $isShowingCompose) {
            AgentComposeView(registry: registry) { agent in
                selectedNexusAgent = agent
            }
        }
        .sheet(isPresented: $isShowingSettings) { settingsSheet }
        .sheet(isPresented: $isShowingDetail) {
            if let a = detailNexusAgent { AgentDetailView(agent: a, registry: registry) }
        }
        .fullScreenCover(item: $selectedNexusAgent) { agent in
            AgentChatView(agent: agent, registry: registry)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Nexus")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(NexusStyle.text)
            Spacer()
            Button { Task { await refreshApprovals() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NexusStyle.muted)
            }.buttonStyle(.plain)
            Button {
                relayUrlDraft = UserDefaults.standard.string(forKey: "relay_url") ?? relay.activeServer?.relayURL ?? ""
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NexusStyle.muted)
            }.buttonStyle(.plain)
            Button { isShowingCompose = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(NexusStyle.blue)
            }.buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(NexusStyle.blue).frame(width: 7, height: 7)
            Text("\(relay.servers.filter { $0.isOnline }.count) of \(relay.servers.count) servers online · \(registry.agents.count) agents")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NexusStyle.muted)
        }
    }

    @ViewBuilder
    private var approvalBadge: some View {
        if approvalCount > 0 && !isLoadingApprovals {
            Button {
                toast = ToastMessage(text: "\(approvalCount) pending approval\(approvalCount == 1 ? "" : "s")", kind: .info)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14, weight: .semibold))
                    Text("\(approvalCount) pending approval\(approvalCount == 1 ? "" : "s")")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, 4)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }.buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: relay.servers.isEmpty ? "server.rack" : "person.2.waveform")
                .font(.system(size: 40)).foregroundStyle(NexusStyle.subtleText)
            Text(relay.servers.isEmpty ? "No servers yet" : "No agents yet")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(NexusStyle.muted)
            Text(relay.servers.isEmpty ? "Pair a server to start" : "Tap + to add your first agent")
                .font(.system(size: 14)).foregroundStyle(NexusStyle.muted)
            Button {
                if relay.servers.isEmpty { isShowingSettings = true } else { isShowingCompose = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: relay.servers.isEmpty ? "link.badge.plus" : "plus")
                    Text(relay.servers.isEmpty ? "Pair Server" : "Add Agent")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20).frame(height: 44)
                .background(NexusStyle.blue, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groupedAgents, id: \.0?.id) { server, agents in
                VStack(alignment: .leading, spacing: 10) {
                    if let s = server {
                        HStack(spacing: 6) {
                            Circle().fill(s.isOnline ? NexusStyle.blue : NexusStyle.subtleText).frame(width: 6, height: 6)
                            Text(s.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(NexusStyle.muted)
                            Spacer()
                            if !s.isOnline {
                                Text("OFFLINE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.orange)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(agents) { agent in
                            agentCard(agent)
                        }
                    }
                }
            }
        }
    }

    private func agentCard(_ agent: NexusAgent) -> some View {
        let isOffline = agent.status == .offline || agent.status == .lostKeys
        return Button { selectedNexusAgent = agent } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOffline ? NexusStyle.line.opacity(0.5) : NexusStyle.blue.opacity(0.12)).frame(width: 40, height: 40)
                    Image(systemName: agent.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(isOffline ? NexusStyle.subtleText : NexusStyle.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(agent.displayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(NexusStyle.text).lineLimit(1)
                        if isOffline { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange) }
                    }
                    if let preview = agent.lastPreview, !preview.isEmpty {
                        Text(preview).font(.system(size: 13)).foregroundStyle(NexusStyle.muted).lineLimit(1)
                    } else if !agent.description.isEmpty {
                        Text(agent.description).font(.system(size: 13)).foregroundStyle(NexusStyle.muted).lineLimit(1)
                    } else {
                        Text(agent.boundSessionID ?? "New chat").font(.system(size: 12, design: .monospaced)).foregroundStyle(NexusStyle.subtleText).lineLimit(1)
                    }
                    if let msgAt = agent.lastMessageAt {
                        Text(RelativeDateTimeFormatter().localizedString(for: msgAt, relativeTo: Date())).font(.system(size: 11)).foregroundStyle(NexusStyle.subtleText)
                    }
                }
                Spacer()
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(NexusStyle.subtleText).frame(width: 28, height: 28)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(NexusStyle.subtleText)
            }
            .padding(12)
            .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
            .opacity(isOffline ? 0.72 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { detailNexusAgent = agent; isShowingDetail = true } label: { Label("Edit / Info", systemImage: "slider.horizontal.3") }
            if agent.status == .offline || agent.status == .lostKeys {
                Button { rePairById(agent.serverID) } label: { Label("Re-pair server", systemImage: "arrow.triangle.2.circlepath") }
            }
            Button { registry.remove(id: agent.id) } label: { Label("Delete agent", systemImage: "trash") }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(relay.servers) { s in
                        HStack(spacing: 10) {
                            Circle().fill(s.isOnline ? NexusStyle.green : NexusStyle.subtleText).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: 15, weight: .medium)).foregroundStyle(NexusStyle.text)
                                Text(s.relayURL).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusStyle.muted)
                            }
                            Spacer()
                            if !s.isOnline {
                                Button("Re-pair") { rePair(s) }.font(.system(size: 13, weight: .semibold)).foregroundStyle(NexusStyle.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if relay.servers.isEmpty {
                        Text("No servers yet. Pair one to add agents.").font(.system(size: 14)).foregroundStyle(NexusStyle.muted)
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Agents are bound to a server. To remove a server's agents from the list, delete them in Agent detail.")
                }
                Section {
                    Button("Pair another server…") {
                        isShowingSettings = false
                        NotificationCenter.default.post(name: Notification.Name("ShowPairingView"), object: nil)
                    }.font(.system(size: 15, weight: .medium))
                }
                Section {
                    Button("App info") {
                        toast = ToastMessage(text: "Nexus \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")", kind: .info)
                    }.font(.system(size: 15))
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { isShowingSettings = false } label: { Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(NexusStyle.muted) } } }
        }.presentationDetents([.medium]).presentationDragIndicator(.visible)
    }

    private func rePair(_ server: ServerProfile) {
        // Post the same pairing intent used on first launch; ServerStore/RelayClient
        // will prompt for the pairing code to restore this server's channel.
        NotificationCenter.default.post(name: Notification.Name("ShowPairingView"), object: server.id)
        isShowingSettings = false
        toast = ToastMessage(text: "Re-pairing \(server.name)…", kind: .info)
    }

    private func rePairById(_ serverID: String) {
        guard let server = relay.servers.first(where: { $0.id == serverID }) ?? relay.servers.first else { return }
        rePair(server)
    }

    /// Reflect each server's live connection state onto its bound agents.
    /// Keep lostKeys intact (that status is set explicitly by pairing failure).
    private func syncStatus() {
        var changed = false
        for server in relay.servers {
            let online = server.isOnline
            for i in registry.agents.indices where registry.agents[i].serverID == server.id && registry.agents[i].status != .lostKeys {
                let newStatus: AgentStatus = online ? .ready : .offline
                if registry.agents[i].status != newStatus {
                    registry.agents[i].status = newStatus
                    registry.agents[i].updatedAt = Date()
                    changed = true
                }
            }
        }
        if changed {
            // Reassign to trigger @Published didSet (index-mutation is in-place).
            registry.agents = registry.agents
        }
    }

    private func refreshApprovals() async {
        guard relay.isConnected else { return }
        isLoadingApprovals = true
        defer { isLoadingApprovals = false }
        if let result = try? await relay.call("approval.list", params: [:]),
           let dict = result as? [String: Any],
           let arr = dict["approvals"] as? [[String: Any]] ?? (dict["items"] as? [[String: Any]]) {
            approvalCount = arr.count
        }
    }
}
