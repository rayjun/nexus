import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("gateway_base_url") private var gatewayBaseUrl = ""
    @State private var deviceId = KeychainHelper.load(key: "device_id")
    @State private var deviceToken = KeychainHelper.load(key: "device_token")
    @State private var deviceName = UIDevice.current.name
    @State private var statusMessage = ""
    @State private var nodeName = ""
    @State private var agents: [AgentInfo] = []
    @State private var sessions: [SessionSummary] = []
    @State private var selectedAgentServer: AgentInfo?
    @State private var selectedSection = "Inbox"
    @State private var isLoadingAgents = false
    @State private var isLoadingSessions = false
    @State private var isShowingComposer = false
    @State private var goalDraft = ""
    @State private var isCreatingSession = false
    @State private var selectedSession: SessionSummary?
    @State private var selectedTimeline: SessionTimeline?
    @State private var resumedSessionIds: [String: String] = [:]
    @State private var isLoadingTimeline = false
    @State private var timelineError = ""
    @State private var followUpDraft = ""
    @State private var isAppendingGoal = false
    @State private var agentNameDraft = ""
    @State private var agentUrlDraft = ""
    @State private var isAddingAgent = false
    @State private var isShowingAddServer = false
    @State private var removingAgentId: String?
    @State private var persistentAgents: [PersistentAgent] = []
    @State private var selectedPersistentAgent: PersistentAgent?
    @State private var agentMessages: [PersistentAgentMessage] = []
    @State private var isLoadingPersistentAgents = false
    @State private var isLoadingAgentMessages = false
    @State private var agentInputDraft = ""
    @State private var isSendingAgentMessage = false
    @State private var isShowingCreateAgent = false
    @State private var newAgentName = ""
    @State private var newAgentDesc = ""
    @State private var isShowingEditServer = false
    @State private var editServerName = ""
    @State private var editServerUrl = ""
    @State private var isShowingEditAgent = false
    @State private var editAgentId = ""
    @State private var editAgentName = ""
    @State private var editAgentDesc = ""
    @State private var editAgentIcon = "sparkles"
    @State private var cronJobs: [CronJobInfo] = []
    @State private var approvalList: [ApprovalInfo] = []
    @State private var artifactList: [ArtifactInfo] = []
    @State private var isLoadingCron = false
    @State private var isLoadingApprovals = false
    @State private var isLoadingArtifacts = false
    @State private var toast: ToastMessage?
    @State private var searchText = ""
    @State private var isShowingSettings = false
    @State private var relayUrlDraft = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var relay: RelayClient

    private var isConnected: Bool {
        relay.isConnected
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                if isConnected {
                    appHome
                } else {
                    connectView
                }
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
        }
        .onAppear {
            if !relay.servers.isEmpty, let serverID = relay.activeServerID, !relay.isConnected {
                relay.connect(serverID: serverID)
            }
        }
        .onChange(of: relay.isConnected) { connected in
            if connected && agents.isEmpty {
                Task { await loadHomeViaWS() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RelayPaired"))) { _ in
            // Peer confirmed present in channel — (re)load home data.
            Task { await loadHomeViaWS() }
        }
        .sheet(isPresented: $isShowingComposer) {
            goalComposer
        }
        .sheet(isPresented: $isShowingCreateAgent) {
            createAgentSheet
        }
        .sheet(isPresented: $isShowingEditAgent) {
            editAgentSheet
        }
        .sheet(isPresented: $isShowingSettings) {
            settingsSheet
        }
        .fullScreenCover(item: $selectedPersistentAgent) { agent in
            NavigationStack {
                agentConversationView(agent)
            }
        }
        .fullScreenCover(item: $selectedSession) { session in
            NavigationStack {
                sessionDetail(session)
            }
        }
    }

    private var connectView: some View {
        // C6: legacy direct-connection UI removed. When the relay is not yet
        // connected we show a lightweight connecting state.
        VStack(spacing: 16) {
            mobileTopBar(title: "Nexus", subtitle: "Agent Control Surface")
            Spacer()
            ProgressView()
                .tint(NexusStyle.blue)
            Text("Connecting to relay…")
                .font(.system(size: 14))
                .foregroundStyle(NexusStyle.muted)
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var appHome: some View {
        if let selectedAgentServer {
            serverDashboard(selectedAgentServer)
                .sheet(isPresented: $isShowingEditServer) {
                    editServerSheet
                }
        } else {
            agentServerList
        }
    }

    private func serverDashboard(_ agent: AgentInfo) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        selectedAgentServer = nil
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Agent servers")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(NexusStyle.blue)
                    }
                    .buttonStyle(.plain)
                    mobileTopBar(title: agent.name, subtitle: agent.baseUrl) {
                        editServerName = agent.name
                        editServerUrl = agent.baseUrl
                        isShowingEditServer = true
                    }
                    segmentedRail
                    contentPanel
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 112)
            }
            commandBar
        }
    }

    private var agentServerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Text("Nexus")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(NexusStyle.text)
                    Spacer()
                    Button {
                        Task { await loadHomeViaWS() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                    .buttonStyle(.plain)
                    Button {
                        relayUrlDraft = UserDefaults.standard.string(forKey: "relay_url") ?? relay.activeServer?.relayURL ?? ""
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                    .buttonStyle(.plain)
                    Button {
                        agentNameDraft = ""
                        agentUrlDraft = ""
                        isShowingAddServer = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(NexusStyle.blue)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(NexusStyle.blue)
                        .frame(width: 7, height: 7)
                    Text("\(agents.filter { $0.status == "online" }.count) of \(agents.count) servers online")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NexusStyle.muted)
                }

                if isLoadingAgents {
                    loadingRows
                        .padding(.horizontal, 2)
                } else if agents.isEmpty {
                    VStack(alignment: .center, spacing: 14) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 40))
                            .foregroundStyle(NexusStyle.subtleText)
                        Text("No servers yet")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(NexusStyle.muted)
                        Button {
                            agentNameDraft = ""
                            agentUrlDraft = ""
                            isShowingAddServer = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("Add Server")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(NexusStyle.blue, in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(agents) { agent in
                            agentServerCard(agent)
                        }
                    }
                }

                if !statusMessage.isEmpty && statusMessage.lowercased().contains("error") {
                    statusPill(text: statusMessage, positive: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background(NexusStyle.background)
        .refreshable {
            await loadHomeViaWS()
        }
        .sheet(isPresented: $isShowingAddServer) {
            addServerSheet
        }
    }

    private var addServerSheet: some View {
        NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    desktopField(title: "SERVER NAME", text: $agentNameDraft, placeholder: "Local Hermes", systemImage: "server.rack")
                    desktopField(title: "SERVER URL", text: $agentUrlDraft, placeholder: "https://your-server:8444", systemImage: "network")
                    Spacer()
                    Button {
                        Task {
                            await addAgent()
                            if !statusMessage.lowercased().contains("error") {
                                isShowingAddServer = false
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isAddingAgent {
                                ProgressView().tint(.white)
                            }
                            Text(isAddingAgent ? "Adding…" : "Add Server")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(canAddAgent ? NexusStyle.blue : NexusStyle.subtleText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(!canAddAgent || isAddingAgent)
                }
                .padding(18)
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingAddServer = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var editServerSheet: some View {
        NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    desktopField(title: "SERVER NAME", text: $editServerName, placeholder: "Server name", systemImage: "server.rack")
                    desktopField(title: "SERVER URL", text: $editServerUrl, placeholder: "http://...", systemImage: "network")
                    Spacer()
                    Button {
                        Task { await updateAgentServer() }
                    } label: {
                        HStack(spacing: 8) {
                            if isAddingAgent {
                                ProgressView().tint(.white)
                            }
                            Text("Save")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(!editServerName.isEmpty ? NexusStyle.blue : NexusStyle.subtleText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(editServerName.isEmpty || isAddingAgent)
                }
                .padding(18)
            }
            .navigationTitle("Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingEditServer = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var segmentedRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["Inbox", "Agents", "Sessions", "Automations", "Artifacts"], id: \.self) { item in
                    Button {
                        selectedSection = item
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(selectedSection == item ? NexusStyle.blue : NexusStyle.subtleText)
                                .frame(width: 6, height: 6)
                            Text(item.uppercased())
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(1.8)
                        }
                        .foregroundStyle(selectedSection == item ? NexusStyle.blue : NexusStyle.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(selectedSection == item ? NexusStyle.selected : .white.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contentPanel: some View {
        switch selectedSection {
        case "Sessions":
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("SESSIONS", count: sessions.count)
                if sessions.count > 5 {
                    TextField("Search sessions…", text: $searchText)
                        .font(.system(size: 14))
                        .foregroundStyle(NexusStyle.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                }
                if isLoadingSessions {
                    loadingRows
                } else if sessions.isEmpty {
                    emptyState(title: "No recent sessions", subtitle: "Start from Desktop or Gateway and they will appear here.")
                } else {
                    let filtered = searchText.isEmpty ? sessions : sessions.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.id.localizedCaseInsensitiveContains(searchText) }
                    ForEach(filtered) { session in
                        Button {
                            selectedTimeline = nil
                            timelineError = ""
                            followUpDraft = ""
                            selectedSession = session
                        } label: {
                            sessionRow(session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .cardStyle()
        case "Agents":
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("AGENTS", count: persistentAgents.count)
                if isLoadingPersistentAgents {
                    loadingRows
                } else if persistentAgents.isEmpty {
                    emptyState(title: "No agents yet", subtitle: "Tap + to create a persistent agent.")
                } else {
                    ForEach(persistentAgents) { agent in
                        agentCardRow(agent)
                    }
                }
            }
            .cardStyle()
        case "Automations":
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("CRON JOBS", count: cronJobs.count)
                if isLoadingCron {
                    loadingRows
                } else if cronJobs.isEmpty {
                    emptyState(title: "No cron jobs", subtitle: "Scheduled tasks will appear here.")
                } else {
                    ForEach(cronJobs) { job in
                        cronJobRow(job)
                    }
                }
            }
            .cardStyle()
        case "Artifacts":
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("ARTIFACTS", count: artifactList.count)
                if isLoadingArtifacts {
                    loadingRows
                } else if artifactList.isEmpty {
                    emptyState(title: "No artifacts yet", subtitle: "Files and generated outputs will land here.")
                } else {
                    ForEach(artifactList) { artifact in
                        artifactRow(artifact)
                    }
                }
            }
            .cardStyle()
        default:
            VStack(alignment: .leading, spacing: 16) {
                let activeSessions = sessions.filter { $0.status == "running" && !$0.id.hasPrefix("mobile-agent-") && !$0.id.hasPrefix("api_") && !$0.id.hasPrefix("api-") }
                sectionHeader("ACTIVE TASKS", count: activeSessions.count)
                if activeSessions.isEmpty {
                    emptyState(title: "No active tasks", subtitle: "Running Hermes sessions will appear here.")
                } else {
                    ForEach(activeSessions.prefix(5)) { session in
                        Button {
                            selectedTimeline = nil
                            timelineError = ""
                            followUpDraft = ""
                            selectedSession = session
                        } label: {
                            activeSessionRow(session)
                        }
                        .buttonStyle(.plain)
                    }
                }

                sectionHeader("APPROVALS", count: approvalList.count)
                if isLoadingApprovals {
                    loadingRows
                } else if approvalList.isEmpty {
                    emptyState(title: "No pending approvals", subtitle: "Approval requests will appear here.")
                } else {
                    ForEach(approvalList) { approval in
                        approvalRow(approval)
                    }
                }
            }
            .cardStyle()
        }
    }

    private func agentServerCard(_ agent: AgentInfo) -> some View {
        let isOnline = agent.status == "online"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isOnline ? NexusStyle.blue.opacity(0.12) : NexusStyle.line.opacity(0.5))
                        .frame(width: 48, height: 48)
                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isOnline ? NexusStyle.blue : NexusStyle.subtleText)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NexusStyle.text)
                    Text(agent.baseUrl)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(NexusStyle.muted)
                        .lineLimit(1)
                }
                Spacer()
                if agent.id != "agent_vps" {
                    Button {
                        Task { await removeAgent(agent) }
                    } label: {
                        if removingAgentId == agent.id {
                            ProgressView().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(.red.opacity(0.7))
                        }
                    }
                    .disabled(removingAgentId == agent.id)
                }
            }
            .padding(16)

            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOnline ? NexusStyle.blue : NexusStyle.subtleText)
                        .frame(width: 6, height: 6)
                    Text(isOnline ? "Online" : "Offline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isOnline ? NexusStyle.blue : NexusStyle.subtleText)
                }
                Text("·")
                    .foregroundStyle(NexusStyle.subtleText)
                Text(agent.profile)
                    .font(.system(size: 12))
                    .foregroundStyle(NexusStyle.muted)
                Text("·")
                    .foregroundStyle(NexusStyle.subtleText)
                Text(agent.model)
                    .font(.system(size: 12))
                    .foregroundStyle(NexusStyle.muted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NexusStyle.subtleText)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            selectedAgentServer = agent
        }
    }

    private var loadingRows: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(NexusStyle.line.opacity(0.55))
                    .frame(height: 54)
            }
        }
        .redacted(reason: .placeholder)
    }

    private func agentCardRow(_ agent: PersistentAgent) -> some View {
        Button {
            selectedPersistentAgent = agent
            agentMessages = []
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(NexusStyle.blue.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: agent.icon.isEmpty ? "sparkles" : agent.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(NexusStyle.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NexusStyle.text)
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.system(size: 12))
                            .foregroundStyle(NexusStyle.muted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text("\(agent.capabilities.count) capabilities")
                            .font(.system(size: 11))
                            .foregroundStyle(NexusStyle.subtleText)
                        Text("·")
                            .foregroundStyle(NexusStyle.subtleText)
                        Text("\(agent.linkedSessionIds.count) sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(NexusStyle.subtleText)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NexusStyle.subtleText)
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editAgentId = agent.id
                editAgentName = agent.name
                editAgentDesc = agent.description
                editAgentIcon = agent.icon
                isShowingEditAgent = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await deleteAgent(agent) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var createAgentSheet: some View {
        NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    desktopField(title: "AGENT NAME", text: $newAgentName, placeholder: "Code Reviewer", systemImage: "sparkles")
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.alignleft")
                            Text("DESCRIPTION")
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.7)
                        .foregroundStyle(NexusStyle.blue)
                        TextField("What does this agent do?", text: $newAgentDesc, axis: .vertical)
                            .font(.system(size: 15))
                            .foregroundStyle(NexusStyle.text)
                            .textInputAutocapitalization(.sentences)
                            .lineLimit(1...3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                    }
                    Spacer()
                    Button {
                        Task {
                            await createAgent()
                            if !statusMessage.lowercased().contains("error") {
                                isShowingCreateAgent = false
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isLoadingPersistentAgents {
                                ProgressView().tint(.white)
                            }
                            Text(isLoadingPersistentAgents ? "Creating…" : "Create Agent")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(!newAgentName.isEmpty ? NexusStyle.blue : NexusStyle.subtleText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(newAgentName.isEmpty || isLoadingPersistentAgents)
                }
                .padding(18)
            }
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingCreateAgent = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var editAgentSheet: some View {
        let icons = ["sparkles", "star", "bolt", "wrench.and.screwdriver", "keyboard", "paintbrush", "magnifyingglass", "shield", "cpu", "globe"]
        return NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("ICON")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.7)
                            .foregroundStyle(NexusStyle.blue)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(icons, id: \.self) { iconName in
                                    Button {
                                        editAgentIcon = iconName
                                    } label: {
                                        ZStack {
                                            Circle()
                                                .fill(editAgentIcon == iconName ? NexusStyle.blue.opacity(0.15) : NexusStyle.line.opacity(0.4))
                                                .frame(width: 40, height: 40)
                                            Image(systemName: iconName)
                                                .font(.system(size: 16))
                                                .foregroundStyle(editAgentIcon == iconName ? NexusStyle.blue : NexusStyle.muted)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    desktopField(title: "AGENT NAME", text: $editAgentName, placeholder: "Agent name", systemImage: "person")
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.alignleft")
                            Text("DESCRIPTION")
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.7)
                        .foregroundStyle(NexusStyle.blue)
                        TextField("What does this agent do?", text: $editAgentDesc, axis: .vertical)
                            .font(.system(size: 15))
                            .foregroundStyle(NexusStyle.text)
                            .textInputAutocapitalization(.sentences)
                            .lineLimit(1...3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                    }
                    Spacer()
                    Button {
                        Task { await updatePersistentAgent() }
                    } label: {
                        HStack(spacing: 8) {
                            if isLoadingPersistentAgents { ProgressView().tint(.white) }
                            Text("Save")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(!editAgentName.isEmpty ? NexusStyle.blue : NexusStyle.subtleText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(editAgentName.isEmpty || isLoadingPersistentAgents)
                }
                .padding(18)
            }
            .navigationTitle("Edit Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingEditAgent = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var settingsSheet: some View {
        NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "iphone")
                                .font(.system(size: 20))
                                .foregroundStyle(NexusStyle.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Device")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(NexusStyle.text)
                                Text(deviceName.isEmpty ? UIDevice.current.name : deviceName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(NexusStyle.muted)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 20))
                                .foregroundStyle(NexusStyle.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Relay Server")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(NexusStyle.text)
                                Text("wss://your-relay-domain/relay")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(NexusStyle.muted)
                            }
                            Spacer()
                        }

                        TextField("wss://your-relay-domain/relay", text: $relayUrlDraft)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))

                        Button {
                            saveRelayUrl()
                        } label: {
                            Text("Save & Reconnect")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(NexusStyle.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Text("Current: \(relay.activeServer?.relayURL ?? "—")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NexusStyle.muted)
                    }
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))

                    Spacer()

                    Button {
                        clearPairing()
                        isShowingSettings = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Disconnect")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 4) {
                        Text("Nexus v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                            .font(.system(size: 12))
                            .foregroundStyle(NexusStyle.subtleText)
                        Text("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(NexusStyle.subtleText)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(18)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingSettings = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func agentConversationView(_ agent: PersistentAgent) -> some View {
        ZStack {
            NexusStyle.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if !agent.capabilities.isEmpty {
                                DisclosureGroup("Capabilities (\(agent.capabilities.count))") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(agent.capabilities, id: \.self) { cap in
                                            HStack(spacing: 5) {
                                                Image(systemName: "checkmark.circle")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(NexusStyle.blue)
                                                Text(cap)
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(NexusStyle.muted)
                                            }
                                        }
                                    }
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NexusStyle.subtleText)
                                .tint(NexusStyle.subtleText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(NexusStyle.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            if isLoadingAgentMessages {
                                loadingRows
                            } else if agentMessages.isEmpty && !isSendingAgentMessage {
                                emptyState(title: "No messages yet", subtitle: "Send a message to start chatting with this agent.")
                                    .padding(.top, 40)
                            } else {
                                ForEach(agentMessages) { msg in
                                    agentChatBubble(msg)
                                        .id(msg.id)
                                        .contextMenu {
                                            Button {
                                                UIPasteboard.general.string = msg.content
                                            } label: {
                                                Label("Copy", systemImage: "doc.on.doc")
                                            }
                                        }
                                }
                                if isSendingAgentMessage {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(spacing: 4) {
                                                TypingDots()
                                                Text("Thinking…")
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundStyle(NexusStyle.subtleText)
                                            }
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                                        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 3)
                                        Spacer(minLength: 52)
                                    }
                                    .id("loading_bubble")
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 100)
                    }
                    .onChange(of: agentMessages.last?.id) { lastId in
                        if let lastId { withAnimation { proxy.scrollTo(lastId, anchor: .bottom) } }
                    }
                    .onChange(of: isSendingAgentMessage) { sending in
                        if sending {
                            withAnimation { proxy.scrollTo("loading_bubble", anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let lastId = agentMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                    .refreshable { await loadAgentMessages(agent) }
                }
                .scrollDismissesKeyboard(.interactively)
                agentInputBar(agent)
            }
        }
        .task(id: agent.id) {
            await loadAgentMessages(agent)
        }
        .navigationTitle(isSendingAgentMessage ? "typing…" : agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    selectedPersistentAgent = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await loadAgentMessages(agent) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private func agentChatBubble(_ msg: PersistentAgentMessage) -> some View {
        let isUser = msg.role == "user"
        let lineCount = msg.content.components(separatedBy: "\n").count
        let shouldCollapse = !isUser && lineCount > 8
        return HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 4) {
                if shouldCollapse && !msgCollapsed(msg.id) {
                    MarkdownText(text: String(msg.content.prefix(200)) + "...", textColor: isUser ? .white : NexusStyle.text)
                    Button {
                        toggleCollapse(msg.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Show full message")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(isUser ? .white.opacity(0.7) : NexusStyle.blue)
                    }
                    .buttonStyle(.plain)
                } else {
                    MarkdownText(text: msg.content, textColor: isUser ? .white : NexusStyle.text)
                    if shouldCollapse {
                        Button {
                            toggleCollapse(msg.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Collapse")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(isUser ? .white.opacity(0.7) : NexusStyle.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 4) {
                    Spacer()
                    Text(formatTime(msg.createdAt))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(isUser ? .white.opacity(0.6) : NexusStyle.subtleText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isUser ? NexusStyle.blue : NexusStyle.bubbleBg,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isUser ? Color.clear : NexusStyle.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isUser ? 0.10 : 0.05), radius: 6, x: 0, y: 2)
            if !isUser { Spacer(minLength: 52) }
        }
    }

    @State private var collapsedMsgIds: Set<String> = []

    private func msgCollapsed(_ id: String) -> Bool {
        collapsedMsgIds.contains(id)
    }

    private func toggleCollapse(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if collapsedMsgIds.contains(id) {
                collapsedMsgIds.remove(id)
            } else {
                collapsedMsgIds.insert(id)
            }
        }
    }

    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else {
            formatter.formatOptions = [.withInternetDateTime]
            guard let d = formatter.date(from: iso) else { return "" }
            return Self.timeFormatter.string(from: d)
        }
        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func agentInputBar(_ agent: PersistentAgent) -> some View {
        HStack(spacing: 10) {
            TextField("Message \(agent.name)…", text: $agentInputDraft, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(NexusStyle.text)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(inputFocused ? NexusStyle.blue : NexusStyle.border, lineWidth: inputFocused ? 2 : 1))
            Button {
                Task { await sendAgentMsg(agent) }
            } label: {
                if isSendingAgentMessage {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 38, height: 38)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                }
            }
            .background(!agentInputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSendingAgentMessage ? NexusStyle.blue : NexusStyle.subtleText, in: Circle())
            .disabled(agentInputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingAgentMessage)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.94))
        .overlay(Rectangle().fill(NexusStyle.border).frame(height: 1), alignment: .top)
    }

    private var commandBar: some View {
        Button {
            newAgentName = ""
            newAgentDesc = ""
            isShowingCreateAgent = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("New Agent")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(NexusStyle.blue, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(NexusStyle.background)
    }

    private var goalComposer: some View {
        NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NEW SESSION")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(NexusStyle.blue)
                        Text("Start with a goal")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(NexusStyle.text)
                        Text("Create a new Hermes session. The agent will run from the connected gateway, not on this device.")
                            .font(.system(size: 14))
                            .foregroundStyle(NexusStyle.muted)
                    }

                    TextEditor(text: $goalDraft)
                        .font(.system(size: 17))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 170)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            if goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Describe the outcome you want Hermes to achieve…")
                                    .font(.system(size: 17))
                                    .foregroundStyle(NexusStyle.subtleText)
                                    .padding(.horizontal, 17)
                                    .padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: 8) {
                        statusChip(icon: "server.rack", text: nodeName.isEmpty ? "Hermes" : nodeName, color: NexusStyle.text)
                        statusChip(icon: "network", text: "Gateway", color: NexusStyle.blue)
                    }

                    Spacer()

                    Button {
                        Task { await createNewSession() }
                    } label: {
                        HStack(spacing: 8) {
                            if isCreatingSession { ProgressView().tint(.white) }
                            Text(isCreatingSession ? "Starting…" : "Start Session")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(canCreateSession ? NexusStyle.blue : NexusStyle.subtleText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(!canCreateSession || isCreatingSession)
                }
                .padding(18)
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingComposer = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sessionDetail(_ session: SessionSummary) -> some View {
        ZStack {
            NexusStyle.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if isLoadingTimeline {
                                loadingRows
                            } else if !timelineError.isEmpty {
                                emptyState(title: "Timeline unavailable", subtitle: timelineError)
                                    .padding(.top, 40)
                            } else if let timeline = selectedTimeline, !timeline.items.isEmpty {
                                ForEach(Array(timeline.items.enumerated()), id: \.element.id) { index, item in
                                    chatBubble(item)
                                        .id(item.id)
                                        .contextMenu {
                                            if let body = item.text ?? item.markdown, !body.isEmpty {
                                                Button {
                                                    UIPasteboard.general.string = body
                                                } label: {
                                                    Label("Copy", systemImage: "doc.on.doc")
                                                }
                                            }
                                        }
                                }
                            } else {
                                emptyState(title: "No messages yet", subtitle: "Send a message to start the conversation.")
                                    .padding(.top, 40)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 100)
                    }
                    .onChange(of: selectedTimeline?.items.last?.id) { lastId in
                        if let lastId {
                            withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let lastId = selectedTimeline?.items.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                followUpBar(for: session)
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    selectedSession = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await loadTimeline(for: session) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task(id: session.id) {
            await loadTimeline(for: session)
        }
    }

    private func followUpBar(for session: SessionSummary) -> some View {
        HStack(spacing: 10) {
            TextField("Continue this session…", text: $followUpDraft, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(NexusStyle.text)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(inputFocused ? NexusStyle.blue : NexusStyle.border, lineWidth: inputFocused ? 2 : 1))
            Button {
                Task { await appendGoal(to: session) }
            } label: {
                if isAppendingGoal {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 38, height: 38)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                }
            }
            .background(canAppendGoal ? NexusStyle.blue : NexusStyle.subtleText, in: Circle())
            .disabled(!canAppendGoal || isAppendingGoal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.94))
        .overlay(Rectangle().fill(NexusStyle.border).frame(height: 1), alignment: .top)
    }

    private var canAppendGoal: Bool {
        !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !deviceToken.isEmpty
    }

    private func toolCallsView(_ calls: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(calls.split(separator: "\n").prefix(6), id: \.self) { call in
                HStack(spacing: 5) {
                    Circle()
                        .fill(NexusStyle.subtleText)
                        .frame(width: 4, height: 4)
                    Text(String(call))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NexusStyle.subtleText)
                        .lineLimit(1)
                }
            }
        }
    }

    private func collapsedBubbleContent(_ item: TimelineItem, body: String, isUser: Bool) -> some View {
        Group {
            if body.isEmpty {
                Text(timelineTitle(item))
                    .font(.system(size: 14))
                    .foregroundStyle(isUser ? .white : NexusStyle.text)
            } else {
                MarkdownText(text: String(body.prefix(200)) + "...", textColor: isUser ? .white : NexusStyle.text)
            }
            Button {
                toggleCollapse(item.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Show full message")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(isUser ? .white.opacity(0.7) : NexusStyle.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private func expandedBubbleContent(_ item: TimelineItem, body: String, isUser: Bool) -> some View {
        Group {
            if body.isEmpty {
                Text(timelineTitle(item))
                    .font(.system(size: 14))
                    .foregroundStyle(isUser ? .white : NexusStyle.text)
            } else {
                MarkdownText(text: body, textColor: isUser ? .white : NexusStyle.text)
            }
        }
    }

    private func thinkingBubbleContent(_ item: TimelineItem, body: String) -> some View {
        DisclosureGroup("Thinking") {
            if !body.isEmpty {
                MarkdownText(text: body, textColor: NexusStyle.subtleText)
            }
            if let calls = item.toolCalls, !calls.isEmpty {
                toolCallsView(calls)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(NexusStyle.subtleText)
        .tint(NexusStyle.subtleText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(NexusStyle.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func collapseButton(_ item: TimelineItem, isUser: Bool) -> some View {
        Button {
            toggleCollapse(item.id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                Text("Collapse")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isUser ? .white.opacity(0.7) : NexusStyle.blue)
        }
        .buttonStyle(.plain)
    }

    private func toolCallsDisclosure(_ calls: String) -> some View {
        DisclosureGroup("Tool calls (\(calls.count))") {
            toolCallsView(calls)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(NexusStyle.subtleText)
        .tint(NexusStyle.subtleText)
    }

    private func chatBubble(_ item: TimelineItem) -> some View {
        let isUser = item.type == "user_goal"
        let isThinking = item.type == "thinking_block"
        let body = item.text ?? item.markdown ?? ""
        let lineCount = body.components(separatedBy: "\n").count
        let shouldCollapse = !isUser && !isThinking && lineCount > 8

        return HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 52) }

            if isThinking {
                thinkingBubbleContent(item, body: body)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if shouldCollapse && !msgCollapsed(item.id) {
                        collapsedBubbleContent(item, body: body, isUser: isUser)
                    } else {
                        expandedBubbleContent(item, body: body, isUser: isUser)
                        if shouldCollapse {
                            collapseButton(item, isUser: isUser)
                        }
                    }

                    if let calls = item.toolCalls, !calls.isEmpty {
                        toolCallsDisclosure(calls)
                    }

                    if !item.timestamp.isEmpty {
                        HStack(spacing: 4) {
                            Spacer()
                            Text(formatTime(item.timestamp))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(isUser ? .white.opacity(0.6) : NexusStyle.subtleText)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isUser ? NexusStyle.blue : NexusStyle.bubbleBg,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isUser ? Color.clear : NexusStyle.border, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(isUser ? 0.10 : 0.05), radius: 6, x: 0, y: 2)
            }

            if !isUser && !isThinking { Spacer(minLength: 52) }
        }
    }

    private func timelineTitle(_ item: TimelineItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        switch item.type {
        case "user_goal": return "User goal"
        case "thinking_block": return "Thinking"
        case "assistant_result": return "Result"
        default: return item.type
        }
    }

    private var canCreateSession: Bool {
        !goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !deviceToken.isEmpty
    }

    private var canAddAgent: Bool {
        !agentNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agentUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !deviceToken.isEmpty
    }

    private func mobileTopBar(title: String, subtitle: String, onSettings: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NexusStyle.selected)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: "rectangle.split.2x1").foregroundStyle(NexusStyle.muted))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(NexusStyle.text)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(NexusStyle.muted)
                        .lineLimit(1)
                }
                Spacer()
                if let onSettings {
                    Button {
                        onSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20))
                            .foregroundStyle(NexusStyle.muted)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(NexusStyle.muted)
                }
            }
        }
    }

    private func desktopField(title: String, text: Binding<String>, placeholder: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.7)
            .foregroundStyle(NexusStyle.blue)
            TextField(placeholder, text: text)
                .font(.system(size: 15))
                .foregroundStyle(NexusStyle.text)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 10))
            Text(title)
                .tracking(3)
            Text("\(count)")
                .tracking(0)
                .foregroundStyle(NexusStyle.subtleText)
            Spacer()
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(NexusStyle.blue)
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.status == "running" ? NexusStyle.blue : NexusStyle.subtleText)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusStyle.text)
                    .lineLimit(1)
                if !session.preview.isEmpty {
                    Text(session.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(NexusStyle.muted)
                        .lineLimit(2)
                }
                Text("\(session.messageCount) messages")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NexusStyle.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NexusStyle.subtleText)
        }
        .padding(12)
        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func cronJobRow(_ job: CronJobInfo) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "clock")
                .foregroundStyle(job.enabled ? NexusStyle.blue : NexusStyle.subtleText)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusStyle.text)
                Text(job.schedule)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(NexusStyle.muted)
            }
            Spacer()
            if job.enabled {
                Circle().fill(NexusStyle.blue).frame(width: 8, height: 8)
            } else {
                Circle().fill(NexusStyle.subtleText).frame(width: 8, height: 8)
            }
        }
        .padding(12)
        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func artifactRow(_ artifact: ArtifactInfo) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "doc")
                .foregroundStyle(NexusStyle.blue)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title ?? artifact.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusStyle.text)
                Text(artifact.summary ?? artifact.type)
                    .font(.system(size: 12))
                    .foregroundStyle(NexusStyle.muted)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func approvalRow(_ approval: ApprovalInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Image(systemName: "terminal")
                    .foregroundStyle(NexusStyle.blue)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.title ?? approval.toolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NexusStyle.text)
                    Text(approval.summary ?? approval.command)
                        .font(.system(size: 12))
                        .foregroundStyle(NexusStyle.muted)
                        .lineLimit(2)
                }
                Spacer()
                Text(approval.status)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(approval.status == "pending" ? NexusStyle.blue : NexusStyle.subtleText)
            }
            if approval.status == "pending" {
                HStack(spacing: 10) {
                    Button {
                        Task { await resolveApproval(id: approval.id, approve: true) }
                    } label: {
                        Text("Approve")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(NexusStyle.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await resolveApproval(id: approval.id, approve: false) }
                    } label: {
                        Text("Deny")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NexusStyle.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(NexusStyle.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @State private var resolvingApprovalId: String?

    private func resolveApproval(id: String, approve: Bool) async {
        resolvingApprovalId = id
        do {
            guard relay.isConnected else { throw NSError(domain: "Nexus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]) }
            _ = try await relay.call("approval.respond", params: ["session_id": id, "decision": approve ? "approve" : "deny"])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            approvalList.removeAll { $0.id == id }
            toast = ToastMessage(text: approve ? "Approved" : "Denied", kind: .success)
        } catch {
            toast = ToastMessage(text: error.localizedDescription, kind: .error)
        }
        resolvingApprovalId = nil
    }

    private func activeSessionRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(NexusStyle.blue.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(NexusStyle.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? session.id : session.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusStyle.text)
                    .lineLimit(1)
                Text(session.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NexusStyle.muted)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(NexusStyle.blue)
                .frame(width: 8, height: 8)
        }
        .padding(12)
        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NexusStyle.text)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(NexusStyle.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(.white.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(NexusStyle.border, lineWidth: 1))
    }

    private func statusPill(text: String, positive: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(positive ? NexusStyle.blue : NexusStyle.subtleText)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(positive ? NexusStyle.blue : NexusStyle.muted)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(NexusStyle.row, in: Capsule())
    }

    private func iconTile(_ systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(NexusStyle.selected)
            .frame(width: 48, height: 48)
            .overlay(Image(systemName: systemName).font(.system(size: 24)).foregroundStyle(NexusStyle.blue))
    }

    private func connect() async {
        // C6: legacy direct-connection removed. RelayClient handles connectivity.
        if let serverID = relay.activeServerID {
            relay.connect(serverID: serverID)
        }
    }

    private func loadHomeViaWS() async {
        guard relay.isConnected else { return }
        isLoadingSessions = true
        isLoadingCron = true
        isLoadingApprovals = true
        isLoadingPersistentAgents = true
        do {
            let sessionsResult = try await relay.call("session.list", params: ["limit": 50])
            var newSessions: [SessionSummary] = []
            if let sessionsArray = (sessionsResult as? [String: Any])?["sessions"] as? [[String: Any]] {
                newSessions = sessionsArray.compactMap { dict in
                    let id = dict["id"] as? String ?? ""
                    let title = dict["title"] as? String ?? "Untitled"
                    let preview = dict["preview"] as? String ?? ""
                    let messageCount = dict["message_count"] as? Int ?? 0
                    let startedAt = dict["started_at"] as? Double ?? 0
                    let dateStr = String(format: "%.3f", startedAt)
                    return SessionSummary(
                        id: id,
                        title: title,
                        preview: preview,
                        messageCount: messageCount,
                        status: "recent",
                        createdAt: dateStr,
                        updatedAt: dateStr
                    )
                }
            }

            // Load cron jobs
            let cronResult = try await relay.call("cron.manage", params: ["action": "list"])
            var newCronJobs: [CronJobInfo] = []
            let cronJobsRaw: [[String: Any]]
            if let result = cronResult as? [String: Any], let jobs = result["jobs"] as? [[String: Any]] {
                cronJobsRaw = jobs
            } else if let result = cronResult as? [[String: Any]] {
                cronJobsRaw = result
            } else {
                cronJobsRaw = []
            }
            newCronJobs = cronJobsRaw.compactMap { dict in
                CronJobInfo(
                    id: dict["job_id"] as? String ?? "",
                    name: dict["name"] as? String ?? "Unnamed",
                    schedule: dict["schedule"] as? String ?? "",
                    enabled: dict["enabled"] as? Bool ?? false,
                    nextRunAt: dict["next_run_at"] as? String,
                    lastRun: nil
                )
            }

            // Build persistent agents from sessions
            let newPersistentAgents = newSessions.prefix(5).compactMap { s -> PersistentAgent? in
                guard !s.id.isEmpty else { return nil }
                return PersistentAgent(
                    id: s.id,
                    name: s.title,
                    description: s.preview.isEmpty ? "Latest conversation" : s.preview,
                    icon: "cpu",
                    capabilities: [],
                    linkedSessionIds: [s.id],
                    createdAt: s.createdAt,
                    updatedAt: s.updatedAt,
                    lastMessageAt: s.updatedAt
                )
            }

            // Update UI on main thread
            await MainActor.run {
                self.sessions = newSessions
                self.cronJobs = newCronJobs
                self.persistentAgents = newPersistentAgents
                self.approvalList = []

                if agents.isEmpty && !newSessions.isEmpty {
                    let defaultServer = AgentInfo(
                        id: "relay",
                        name: "Hermes Agent",
                        baseUrl: "relay",
                        status: "online",
                        profile: "default",
                        model: "",
                        createdAt: "",
                        lastSeenAt: nil
                    )
                    self.agents = [defaultServer]
                    self.selectedAgentServer = defaultServer
                }

                self.isLoadingSessions = false
                self.isLoadingCron = false
                self.isLoadingApprovals = false
                self.isLoadingPersistentAgents = false
            }
        } catch {
            await MainActor.run {
                self.statusMessage = "Failed to load: \(error.localizedDescription)"
                self.isLoadingSessions = false
                self.isLoadingCron = false
                self.isLoadingApprovals = false
                self.isLoadingPersistentAgents = false
            }
        }
    }

    private func cacheToDisk() {
        let cache: [String: Any] = [
            "nodeName": nodeName,
            "timestamp": Date().timeIntervalSince1970
        ]
        UserDefaults.standard.set(cache, forKey: "nexus_cache")
    }

    private func loadFromCache() {
        guard let cache = UserDefaults.standard.dictionary(forKey: "nexus_cache") else { return }
        if let name = cache["nodeName"] as? String { nodeName = name }
    }

    private func createAgent() async {
        // No-op: agent creation not available via WebSocket RPC
    }

    private func deleteAgent(_ agent: PersistentAgent) async {
        // No-op: agent deletion not available via WebSocket RPC
    }

    private func updatePersistentAgent() async {
        // No-op: agent update not available via WebSocket RPC
    }

    private func sessionMessages(for sourceSessionId: String) async throws -> (activeSessionId: String, messages: [[String: Any]]) {
        guard relay.isConnected else {
            throw NSError(domain: "Nexus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        if let activeSessionId = await MainActor.run(body: { resumedSessionIds[sourceSessionId] }) {
            do {
                let result = try await relay.call("session.history", params: ["session_id": activeSessionId])
                if let resultDict = result as? [String: Any], let messages = resultDict["messages"] as? [[String: Any]] {
                    return (activeSessionId, messages)
                }
            } catch {
                await MainActor.run { _ = resumedSessionIds.removeValue(forKey: sourceSessionId) }
            }
        }

        let result = try await relay.call("session.resume", params: ["session_id": sourceSessionId, "cols": 80])
        guard let resultDict = result as? [String: Any] else {
            throw NSError(domain: "Nexus", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid session response"])
        }
        guard let activeSessionId = resultDict["session_id"] as? String, !activeSessionId.isEmpty else {
            throw NSError(domain: "Nexus", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing active session ID"])
        }
        guard let messages = resultDict["messages"] as? [[String: Any]] else {
            throw NSError(domain: "Nexus", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid session messages"])
        }
        await MainActor.run { resumedSessionIds[sourceSessionId] = activeSessionId }
        return (activeSessionId, messages)
    }

    private func loadAgentMessages(_ agent: PersistentAgent) async {
        isLoadingAgentMessages = true
        do {
            let session = try await sessionMessages(for: agent.id)
            let recentMessages = Array(session.messages.suffix(200))
            let msgs = recentMessages.compactMap { dict -> PersistentAgentMessage? in
                let role = dict["role"] as? String ?? "user"
                let text = dict["text"] as? String ?? dict["content"] as? String ?? ""
                guard !text.isEmpty || role == "tool" else { return nil }
                return PersistentAgentMessage(
                    id: UUID().uuidString,
                    agentId: agent.id,
                    role: role,
                    content: text.isEmpty ? (dict["name"] as? String ?? "") + ": " + (dict["context"] as? String ?? "") : text,
                    createdAt: ""
                )
            }
            await MainActor.run {
                self.agentMessages = msgs
                self.isLoadingAgentMessages = false
            }
        } catch {
            await MainActor.run {
                self.statusMessage = error.localizedDescription
                self.isLoadingAgentMessages = false
            }
        }
    }

    private func sendAgentMsg(_ agent: PersistentAgent) async {
        let text = agentInputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSendingAgentMessage = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        agentInputDraft = ""

        let now = ISO8601DateFormatter().string(from: Date())
        let localUserMsg = PersistentAgentMessage(
            id: "local_\(UUID().uuidString.prefix(8))",
            agentId: agent.id,
            role: "user",
            content: text,
            createdAt: now
        )
        agentMessages.append(localUserMsg)

        do {
            guard relay.isConnected else { throw NSError(domain: "Nexus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]) }
            let session = try await sessionMessages(for: agent.id)
            _ = try await relay.call("prompt.submit", params: ["session_id": session.activeSessionId, "text": text])
            await loadAgentMessages(agent)
        } catch {
            agentInputDraft = text
            agentMessages.removeAll { $0.id == localUserMsg.id }
            toast = ToastMessage(text: error.localizedDescription, kind: .error)
        }
        isSendingAgentMessage = false
    }

    private func addAgent() async {
        let name = agentNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = normalized(agentUrlDraft)
        guard !name.isEmpty, !url.isEmpty else { return }
        isAddingAgent = true
        // Add server locally — no WebSocket RPC for adding remote agent servers
        let server = AgentInfo(
            id: UUID().uuidString,
            name: name,
            baseUrl: url,
            status: "offline",
            profile: "default",
            model: "default",
            createdAt: String(Int(Date().timeIntervalSince1970)),
            lastSeenAt: nil
        )
        agents.append(server)
        agentNameDraft = ""
        agentUrlDraft = ""
        statusMessage = "Added \(name)"
        isAddingAgent = false
    }

    private func updateAgentServer() async {
        guard let server = selectedAgentServer else { return }
        let name = editServerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = editServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isAddingAgent = true
        // Update server locally — no WebSocket RPC for updating remote agent servers
        let updated = AgentInfo(
            id: server.id,
            name: name,
            baseUrl: url.isEmpty ? server.baseUrl : url,
            status: server.status,
            profile: server.profile,
            model: server.model,
            createdAt: server.createdAt,
            lastSeenAt: server.lastSeenAt
        )
        if let idx = agents.firstIndex(where: { $0.id == server.id }) {
            agents[idx] = updated
        }
        selectedAgentServer = updated
        isShowingEditServer = false
        statusMessage = "Updated \(name)"
        isAddingAgent = false
    }

    private func removeAgent(_ agent: AgentInfo) async {
        removingAgentId = agent.id
        // Remove server locally — no WebSocket RPC for removing remote agent servers
        agents.removeAll { $0.id == agent.id }
        statusMessage = "Removed \(agent.name)"
        removingAgentId = nil
    }

    private func createNewSession() async {
        let goal = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        isCreatingSession = true
        do {
            guard relay.isConnected else { throw NSError(domain: "Nexus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]) }
            _ = try await relay.call("session.create", params: [:])
            _ = try await relay.call("prompt.submit", params: ["session_id": "new", "text": goal])
            await loadHomeViaWS()
            selectedSection = "Sessions"
            toast = ToastMessage(text: "Session started", kind: .success)
            isShowingComposer = false
            goalDraft = ""
        } catch {
            statusMessage = error.localizedDescription
        }
        isCreatingSession = false
    }

    private func loadTimeline(for session: SessionSummary) async {
        isLoadingTimeline = true
        timelineError = ""
        do {
            let sessionState = try await sessionMessages(for: session.id)
            let recentMessages = Array(sessionState.messages.suffix(200))
            let items = recentMessages.compactMap { dict -> TimelineItem? in
                let id = UUID().uuidString
                let role = dict["role"] as? String ?? "message"
                let type = role == "user" ? "user_goal" : (role == "tool" ? "tool_call" : "message")
                let text = dict["text"] as? String ?? dict["content"] as? String
                let name = dict["name"] as? String
                let context = dict["context"] as? String
                let toolCalls = name != nil ? "\(name ?? ""): \(context ?? "")" : nil
                return TimelineItem(id: id, type: type, text: text, markdown: nil, title: name, timestamp: "", toolName: name, toolCalls: toolCalls)
            }
            await MainActor.run {
                self.selectedTimeline = SessionTimeline(items: items)
            }
        } catch {
            await MainActor.run {
                self.selectedTimeline = nil
                self.timelineError = error.localizedDescription
            }
        }
        await MainActor.run { self.isLoadingTimeline = false }
    }

    private func appendGoal(to session: SessionSummary) async {
        let text = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAppendingGoal = true
        timelineError = ""
        do {
            guard relay.isConnected else { throw NSError(domain: "Nexus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]) }
            let sessionState = try await sessionMessages(for: session.id)
            _ = try await relay.call("prompt.submit", params: ["session_id": sessionState.activeSessionId, "text": text])
            await loadTimeline(for: session)
            followUpDraft = ""
        } catch {
            timelineError = error.localizedDescription
            toast = ToastMessage(text: error.localizedDescription, kind: .error)
        }
        isAppendingGoal = false
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func clearPairing() {
        deviceId = ""
        deviceToken = ""
        KeychainHelper.delete(key: "device_id")
        KeychainHelper.delete(key: "device_token")
        sessions = []
        persistentAgents = []
        resumedSessionIds = [:]
        agentMessages = []
        selectedTimeline = nil
        relay.disconnect()
        
        agents = []
        nodeName = ""
        statusMessage = "Disconnected"
    }

    private func saveRelayUrl() {
        let trimmed = relayUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme == "wss" || url.scheme == "ws" else {
            toast = ToastMessage(text: "Enter a valid wss:// relay URL", kind: .error)
            return
        }
        UserDefaults.standard.set(trimmed, forKey: "relay_url")
        relay.disconnect()
        if let serverID = relay.activeServerID {
            relay.connect(serverID: serverID)
        }
        isShowingSettings = false
        toast = ToastMessage(text: "Relay updated, reconnecting…", kind: .success)
    }
}

private enum NexusStyle {
    static let background = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1) :
            UIColor(red: 0.965, green: 0.976, blue: 0.992, alpha: 1)
    })
    static let card = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 0.9) :
            UIColor.white.withAlphaComponent(0.86)
    })
    static let row = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1) :
            UIColor(red: 0.975, green: 0.981, blue: 0.992, alpha: 1)
    })
    static let selected = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.15, green: 0.20, blue: 0.30, alpha: 1) :
            UIColor(red: 0.86, green: 0.902, blue: 0.978, alpha: 1)
    })
    static let line = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.22, green: 0.23, blue: 0.26, alpha: 1) :
            UIColor(red: 0.87, green: 0.895, blue: 0.94, alpha: 1)
    })
    static let border = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.28, green: 0.30, blue: 0.35, alpha: 1) :
            UIColor(red: 0.80, green: 0.842, blue: 0.91, alpha: 1)
    })
    static let blue = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1) :
            UIColor(red: 0.03, green: 0.345, blue: 0.94, alpha: 1)
    })
    static let green = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.25, green: 0.70, blue: 0.45, alpha: 1) :
            UIColor(red: 0.12, green: 0.56, blue: 0.34, alpha: 1)
    })
    static let text = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1) :
            UIColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1)
    })
    static let muted = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.70, green: 0.72, blue: 0.76, alpha: 1) :
            UIColor(red: 0.47, green: 0.49, blue: 0.54, alpha: 1)
    })
    static let subtleText = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1) :
            UIColor(red: 0.66, green: 0.68, blue: 0.73, alpha: 1)
    })
    static let bubbleBg = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ?
            UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1) :
            UIColor.white
    })
}

private extension View {
    func cardStyle() -> some View {
        padding(14)
            .background(NexusStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.035), radius: 16, x: 0, y: 8)
    }
}

private struct MarkdownText: View {
    let text: String
    let textColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .codeBlock(let lang, let code):
                    CodeBlockView(code: code, language: lang)
                case .heading(let level, let content):
                    Text(inlineAttributed(content))
                        .font(.system(size: level == 1 ? 17 : (level == 2 ? 15 : 14), weight: .bold))
                        .foregroundStyle(textColor)
                case .paragraph(let content):
                    Text(inlineAttributed(content))
                        .font(.system(size: 14))
                        .foregroundStyle(textColor)
                case .bullet(let content, let level):
                    HStack(alignment: .top, spacing: 6) {
                        if level > 0 {
                            Text("◦")
                                .font(.system(size: 14))
                                .foregroundStyle(textColor.opacity(0.6))
                                .frame(width: 14, alignment: .leading)
                        } else {
                            Text("•")
                                .font(.system(size: 14))
                                .foregroundStyle(textColor)
                                .frame(width: 14, alignment: .leading)
                        }
                        Text(inlineAttributed(content))
                            .font(.system(size: 14))
                            .foregroundStyle(textColor)
                    }
                    .padding(.leading, CGFloat(level) * 16)
                case .ordered(let index, let content):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index).")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(textColor)
                            .frame(width: 20, alignment: .leading)
                        Text(inlineAttributed(content))
                            .font(.system(size: 14))
                            .foregroundStyle(textColor)
                    }
                case .quote(let content):
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(textColor.opacity(0.25))
                            .frame(width: 3)
                        Text(inlineAttributed(content))
                            .font(.system(size: 13))
                            .foregroundStyle(textColor.opacity(0.75))
                            .italic()
                    }
                case .divider:
                    Rectangle()
                        .fill(textColor.opacity(0.12))
                        .frame(height: 1)
                }
            }
        }
    }

    private enum Block {
        case codeBlock(String, String)
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, Int)
        case ordered(Int, String)
        case quote(String)
        case divider
    }

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                result.append(.codeBlock(lang, codeLines.joined(separator: "\n")))
            } else if line.hasPrefix("### ") {
                result.append(.heading(3, String(line.dropFirst(4))))
                i += 1
            } else if line.hasPrefix("## ") {
                result.append(.heading(2, String(line.dropFirst(3))))
                i += 1
            } else if line.hasPrefix("# ") {
                result.append(.heading(1, String(line.dropFirst(2))))
                i += 1
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.bullet(String(line.dropFirst(2)), 0))
                i += 1
            } else if line.hasPrefix("  - ") || line.hasPrefix("  * ") {
                result.append(.bullet(String(line.dropFirst(4)), 1))
                i += 1
            } else if let orderedMatch = matchOrdered(line) {
                result.append(.ordered(orderedMatch.0, orderedMatch.1))
                i += 1
            } else if line.hasPrefix("> ") {
                result.append(.quote(String(line.dropFirst(2))))
                i += 1
            } else if line.hasPrefix("---") || line.hasPrefix("***") {
                if line.allSatisfy({ $0 == "-" || $0 == "*" }) {
                    result.append(.divider)
                    i += 1
                } else {
                    result.append(.paragraph(line))
                    i += 1
                }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
            } else {
                result.append(.paragraph(line))
                i += 1
            }
        }
        return result
    }

    private func matchOrdered(_ line: String) -> (Int, String)? {
        var num = ""
        var rest = line
        while let first = rest.first, first.isNumber {
            num.append(first)
            rest = String(rest.dropFirst())
        }
        guard !num.isEmpty, rest.hasPrefix(". ") else { return nil }
        guard let n = Int(num) else { return nil }
        return (n, String(rest.dropFirst(2)))
    }

    private func inlineAttributed(_ s: String) -> AttributedString {
        var result = AttributedString()
        var remaining = s
        while !remaining.isEmpty {
            if let range = remaining.range(of: "`") {
                let before = String(remaining[..<range.lowerBound])
                remaining = String(remaining[range.upperBound...])
                if let closeRange = remaining.range(of: "`") {
                    let code = String(remaining[..<closeRange.lowerBound])
                    remaining = String(remaining[closeRange.upperBound...])
                    if !before.isEmpty {
                        result.append(AttributedString(before))
                    }
                    var codeAttr = AttributedString(code)
                    codeAttr.font = .system(.body, design: .monospaced)
                    codeAttr.foregroundColor = textColor
                    codeAttr.backgroundColor = .black.opacity(0.06)
                    result.append(codeAttr)
                } else {
                    result.append(AttributedString(before + "`" + remaining))
                    remaining = ""
                }
            } else if let range = remaining.range(of: "[") {
                let before = String(remaining[..<range.lowerBound])
                remaining = String(remaining[range.upperBound...])
                if let closeBracket = remaining.range(of: "](") {
                    let linkText = String(remaining[..<closeBracket.lowerBound])
                    remaining = String(remaining[closeBracket.upperBound...])
                    if let closeParen = remaining.range(of: ")") {
                        let linkUrl = String(remaining[..<closeParen.lowerBound])
                        remaining = String(remaining[closeParen.upperBound...])
                        if !before.isEmpty {
                            result.append(AttributedString(before))
                        }
                        var linkAttr = AttributedString(linkText)
                        linkAttr.foregroundColor = NexusStyle.blue
                        linkAttr.font = .system(size: 14)
                        linkAttr.link = URL(string: linkUrl)
                        result.append(linkAttr)
                    } else {
                        result.append(AttributedString(before + "[" + remaining))
                        remaining = ""
                    }
                } else {
                    result.append(AttributedString(before + "[" + remaining))
                    remaining = ""
                }
            } else if let range = remaining.range(of: "**") {
                let before = String(remaining[..<range.lowerBound])
                remaining = String(remaining[range.upperBound...])
                if let closeRange = remaining.range(of: "**") {
                    let bold = String(remaining[..<closeRange.lowerBound])
                    remaining = String(remaining[closeRange.upperBound...])
                    if !before.isEmpty {
                        result.append(AttributedString(before))
                    }
                    var boldAttr = AttributedString(bold)
                    boldAttr.font = .system(.body, design: .default).bold()
                    boldAttr.foregroundColor = textColor
                    result.append(boldAttr)
                } else {
                    result.append(AttributedString(before + "**" + remaining))
                    remaining = ""
                }
            } else if let range = remaining.range(of: "*") {
                let before = String(remaining[..<range.lowerBound])
                remaining = String(remaining[range.upperBound...])
                if let closeRange = remaining.range(of: "*") {
                    let italic = String(remaining[..<closeRange.lowerBound])
                    remaining = String(remaining[closeRange.upperBound...])
                    if !before.isEmpty {
                        result.append(AttributedString(before))
                    }
                    var italicAttr = AttributedString(italic)
                    italicAttr.font = .system(.body, design: .default).italic()
                    italicAttr.foregroundColor = textColor
                    result.append(italicAttr)
                } else {
                    result.append(AttributedString(before + "*" + remaining))
                    remaining = ""
                }
            } else {
                result.append(AttributedString(remaining))
                remaining = ""
            }
        }
        return result
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String

    @State private var copied = false
    @State private var expanded = false

    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "struct",
        "class", "enum", "import", "guard", "switch", "case", "break", "continue",
        "defer", "in", "where", "try", "catch", "throw", "throws", "async", "await",
        "public", "private", "internal", "static", "self", "init", "deinit",
        "true", "false", "nil", "some", "any", "extension", "protocol", "override",
        "final", "open", "weak", "unowned", "inout", "mutating", "nonmutating",
        "const", "def", "print", "lambda", "with", "as", "pass", "None", "True",
        "False", "from", "yield", "raise", "except", "finally", "elif", "global",
        "fn", "pub", "use", "mod", "impl", "trait", "match", "loop", "unsafe",
        "int", "string", "bool", "float", "double", "void", "char", "long",
        "short", "unsigned", "signed", "sizeof", "typedef", "namespace",
        "template", "virtual", "new", "delete", "this", "nullptr",
    ]

    private var lineCount: Int {
        code.components(separatedBy: "\n").count
    }

    private var shouldCollapse: Bool {
        lineCount > 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Color(red: 0.5, green: 0.55, blue: 0.65))
                }
                if shouldCollapse {
                    Text("\(lineCount) lines")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 0.5, green: 0.55, blue: 0.65))
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation(.easeInOut(duration: 0.2)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(copied ? Color(red: 0.5, green: 0.85, blue: 0.55) : Color(red: 0.5, green: 0.55, blue: 0.65))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlightedCode)
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(2)
                    .padding(10)
            }
            .frame(maxHeight: shouldCollapse && !expanded ? 180 : .infinity)
            .clipped()

            if shouldCollapse {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(expanded ? "Collapse" : "Show all \(lineCount) lines")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color(red: 0.5, green: 0.55, blue: 0.65))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(red: 0.12, green: 0.13, blue: 0.17), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var highlightedCode: AttributedString {
        var result = AttributedString()
        let lines = code.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            result.append(highlightLine(line))
            if idx < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private func highlightLine(_ line: String) -> AttributedString {
        var result = AttributedString()
        var remaining = line

        while !remaining.isEmpty {
            if remaining.hasPrefix("//") {
                var comment = AttributedString(remaining)
                comment.foregroundColor = Color(red: 0.42, green: 0.45, blue: 0.52)
                result.append(comment)
                break
            }

            if remaining.hasPrefix("#") && (language.isEmpty || language == "python" || language == "bash" || language == "sh") {
                var comment = AttributedString(remaining)
                comment.foregroundColor = Color(red: 0.42, green: 0.45, blue: 0.52)
                result.append(comment)
                break
            }

            if remaining.hasPrefix("\"") {
                if let endIdx = remaining.dropFirst().firstIndex(of: "\"") {
                    let str = String(remaining[...endIdx])
                    var attr = AttributedString(str)
                    attr.foregroundColor = Color(red: 0.78, green: 0.87, blue: 0.55)
                    result.append(attr)
                    remaining = String(remaining[remaining.index(after: endIdx)...])
                    continue
                }
            }

            var wordEnd = remaining.startIndex
            while wordEnd < remaining.endIndex, remaining[wordEnd].isLetter || remaining[wordEnd] == "_" || remaining[wordEnd].isNumber {
                wordEnd = remaining.index(after: wordEnd)
            }

            if wordEnd == remaining.startIndex {
                var attr = AttributedString(String(remaining.first!))
                attr.foregroundColor = Color(red: 0.85, green: 0.87, blue: 0.92)
                result.append(attr)
                remaining = String(remaining.dropFirst())
                continue
            }

            let word = String(remaining[..<wordEnd])

            if Self.keywords.contains(word) {
                var attr = AttributedString(word)
                attr.foregroundColor = Color(red: 0.55, green: 0.78, blue: 0.95)
                attr.font = .system(size: 12, design: .monospaced).bold()
                result.append(attr)
            } else if word.allSatisfy({ $0.isNumber }) {
                var attr = AttributedString(word)
                attr.foregroundColor = Color(red: 0.92, green: 0.72, blue: 0.55)
                result.append(attr)
            } else if word.first?.isUppercase == true {
                var attr = AttributedString(word)
                attr.foregroundColor = Color(red: 0.88, green: 0.76, blue: 0.62)
                result.append(attr)
            } else {
                var attr = AttributedString(word)
                attr.foregroundColor = Color(red: 0.85, green: 0.87, blue: 0.92)
                result.append(attr)
            }

            remaining = String(remaining[wordEnd...])
        }

        return result
    }
}

private struct MarkdownText_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            MarkdownText(text: "Hello `world` and **bold** and *italic*", textColor: .black)
            MarkdownText(text: "```swift\nfunc hello() {\n  print(\"hi\")\n}\n```", textColor: .black)
            MarkdownText(text: "1. First\n2. Second\n3. Third", textColor: .black)
            MarkdownText(text: "> A wise quote", textColor: .black)
        }
        .padding()
        .background(Color(red: 0.965, green: 0.976, blue: 0.992))
    }
}

private struct ToastMessage: Identifiable {
    let id = UUID()
    let text: String
    let kind: Kind

    enum Kind {
        case success, error
    }
}

private struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.kind == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(message.kind == .success ? NexusStyle.blue : .red)
            Text(message.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NexusStyle.text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

private struct TypingDots: View {
    @State private var offset = 0.0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(NexusStyle.subtleText)
                    .frame(width: 5, height: 5)
                    .offset(y: offset)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever()
                            .delay(Double(i) * 0.15),
                        value: offset
                    )
            }
        }
        .onAppear { offset = -4 }
    }
}

#Preview {
    ContentView()
}
