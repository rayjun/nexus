import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("gateway_base_url") private var gatewayBaseUrl = "http://127.0.0.1:8765"
    @State private var deviceId = KeychainHelper.load(key: "device_id")
    @State private var deviceToken = KeychainHelper.load(key: "device_token")
    @State private var gatewayInput = "http://127.0.0.1:8765"
    @State private var deviceName = UIDevice.current.name
    @State private var statusMessage = ""
    @State private var nodeName = ""
    @State private var agents: [AgentInfo] = []
    @State private var sessions: [SessionSummary] = []
    @State private var selectedAgentServer: AgentInfo?
    @State private var selectedSection = "Inbox"
    @State private var isConnecting = false
    @State private var isLoadingAgents = false
    @State private var isLoadingSessions = false
    @State private var isShowingComposer = false
    @State private var goalDraft = ""
    @State private var isCreatingSession = false
    @State private var selectedSession: SessionSummary?
    @State private var selectedTimeline: SessionTimeline?
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
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var isConnected: Bool {
        !deviceId.isEmpty && !deviceToken.isEmpty
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
        .preferredColorScheme(.light)
        .onAppear {
            gatewayInput = gatewayBaseUrl
            if isConnected {
                Task { await loadHome() }
            } else {
                Task { await connect() }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && isConnected && agents.isEmpty {
                Task { await loadHome() }
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                mobileTopBar(title: "Nexus", subtitle: "Agent Control Surface")

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        iconTile("bolt.horizontal.circle.fill")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connect to Hermes")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(NexusStyle.text)
                            Text("Pair this iPhone with your local Hermes gateway.")
                                .font(.system(size: 14))
                                .foregroundStyle(NexusStyle.muted)
                        }
                    }

                    VStack(spacing: 10) {
                        desktopField(title: "GATEWAY", text: $gatewayInput, placeholder: "http://127.0.0.1:8765", systemImage: "network")
                        desktopField(title: "DEVICE", text: $deviceName, placeholder: "Ray iPhone", systemImage: "iphone")
                    }

                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            if isConnecting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            Text(isConnecting ? "Connecting" : "Connect and Enter")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(NexusStyle.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isConnecting || normalized(gatewayInput).isEmpty)

                    if !statusMessage.isEmpty {
                        statusPill(text: statusMessage, positive: statusMessage.hasPrefix("Connected"))
                    }
                }
                .cardStyle()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
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
                        Task { await loadHome() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
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
        .refreshable { await loadHome() }
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
                    desktopField(title: "SERVER URL", text: $agentUrlDraft, placeholder: "http://100.x.y.z:8765", systemImage: "network")
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
                if isLoadingSessions {
                    loadingRows
                } else if sessions.isEmpty {
                    emptyState(title: "No recent sessions", subtitle: "Start from Desktop or Gateway and they will appear here.")
                } else {
                    ForEach(sessions.prefix(8)) { session in
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
            Task { await loadAgentMessages(agent) }
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
                isUser ? NexusStyle.blue : .white,
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

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relativeDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func relativeTime(_ iso: String) -> String {
        let date = Self.isoFormatter.date(from: iso) ?? Self.isoFormatterNoFraction.date(from: iso)
        guard let date else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        return Self.relativeDateFormatter.string(from: date)
    }

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
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(NexusStyle.blue)
                Text("Start with an agent")
                    .font(.system(size: 16))
                    .foregroundStyle(NexusStyle.muted)
                Spacer()
                Circle()
                    .fill(NexusStyle.blue)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(.white.opacity(0.92))
        .overlay(Rectangle().fill(NexusStyle.border).frame(height: 1), alignment: .top)
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

    private func chatBubble(_ item: TimelineItem) -> some View {
        let isUser = item.type == "user_goal"
        let isThinking = item.type == "thinking_block"
        let body = item.text ?? item.markdown ?? ""
        let lineCount = body.components(separatedBy: "\n").count
        let shouldCollapse = !isUser && !isThinking && lineCount > 8

        return HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 52) }

            if isThinking {
                DisclosureGroup("Thinking") {
                    if !body.isEmpty {
                        MarkdownText(text: body, textColor: NexusStyle.subtleText)
                    }
                    if let calls = item.toolCalls, !calls.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(calls.prefix(6)) { call in
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(call.status == "failed" ? .red : NexusStyle.subtleText)
                                        .frame(width: 4, height: 4)
                                    Text(call.summary)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(NexusStyle.subtleText)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(NexusStyle.subtleText)
                .tint(NexusStyle.subtleText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(NexusStyle.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if shouldCollapse && !msgCollapsed(item.id) {
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
                    } else {
                        if body.isEmpty {
                            Text(timelineTitle(item))
                                .font(.system(size: 14))
                                .foregroundStyle(isUser ? .white : NexusStyle.text)
                        } else {
                            MarkdownText(text: body, textColor: isUser ? .white : NexusStyle.text)
                        }
                        if shouldCollapse {
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
                    }

                    if let calls = item.toolCalls, !calls.isEmpty {
                        DisclosureGroup("Tool calls (\(calls.count))") {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(calls.prefix(8)) { call in
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(call.status == "failed" ? .red : (call.status == "running" ? NexusStyle.blue : NexusStyle.subtleText))
                                            .frame(width: 4, height: 4)
                                        Text(call.summary)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(call.status == "failed" ? .red : NexusStyle.muted)
                                            .lineLimit(2)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NexusStyle.subtleText)
                        .tint(NexusStyle.subtleText)
                    }

                    if !item.createdAt.isEmpty {
                        HStack(spacing: 4) {
                            Spacer()
                            Text(formatTime(item.createdAt))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(isUser ? .white.opacity(0.6) : NexusStyle.subtleText)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isUser ? NexusStyle.blue : .white,
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
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusStyle.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.status.capitalized)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.status == "running" ? NexusStyle.blue : NexusStyle.muted)
                    if !session.updatedAt.isEmpty {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(NexusStyle.subtleText)
                        Text(relativeTime(session.updatedAt))
                            .font(.system(size: 11))
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
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
                Text(artifact.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusStyle.text)
                Text(artifact.summary)
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
        HStack(spacing: 11) {
            Image(systemName: "terminal")
                .foregroundStyle(NexusStyle.blue)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(approval.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusStyle.text)
                Text(approval.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(NexusStyle.muted)
                    .lineLimit(2)
            }
            Spacer()
            Text(approval.status)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(approval.status == "pending" ? NexusStyle.blue : NexusStyle.subtleText)
        }
        .padding(12)
        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        isConnecting = true
        statusMessage = "Connecting..."
        do {
            let url = normalized(gatewayInput)
            let client = MobileGatewayClient(baseURL: url)
            let status = try await client.status()
            let pairing = try await client.startPairing()
            let completed = try await client.completePairing(code: pairing.code, deviceName: deviceName.isEmpty ? UIDevice.current.name : deviceName, platform: "ios")
            gatewayBaseUrl = url
            deviceId = completed.deviceId
            deviceToken = completed.deviceToken
            KeychainHelper.save(completed.deviceId, key: "device_id")
            KeychainHelper.save(completed.deviceToken, key: "device_token")
            nodeName = status.nodeName
            statusMessage = "Connected to \(status.nodeName)"
            await loadHome()
        } catch {
            statusMessage = error.localizedDescription
        }
        isConnecting = false
    }

    private func loadHome() async {
        isLoadingAgents = true
        isLoadingSessions = true
        isLoadingPersistentAgents = true
        isLoadingCron = true
        isLoadingApprovals = true
        isLoadingArtifacts = true
        do {
            try await fetchAllData()
        } catch MobileGatewayError.badStatus(401) {
            statusMessage = "Reconnecting..."
            await reconnect()
            isLoadingAgents = false
            isLoadingSessions = false
            isLoadingPersistentAgents = false
            isLoadingCron = false
            isLoadingApprovals = false
            isLoadingArtifacts = false
            return
        } catch {
            statusMessage = error.localizedDescription
        }
        isLoadingAgents = false
        isLoadingSessions = false
        isLoadingPersistentAgents = false
        isLoadingCron = false
        isLoadingApprovals = false
        isLoadingArtifacts = false
    }

    private func fetchAllData() async throws {
        let client = makeClient()
        async let statusResult = client.status()
        async let agentsResult = client.agents(deviceToken: deviceToken)
        async let sessionsResult = client.sessions(deviceToken: deviceToken)
        async let persistentResult = client.persistentAgents(deviceToken: deviceToken)
        async let cronResult = client.cronJobs(deviceToken: deviceToken)
        async let approvalsResult = client.approvals(deviceToken: deviceToken)
        async let artifactsResult = client.artifacts(deviceToken: deviceToken)
        nodeName = try await statusResult.nodeName
        agents = try await agentsResult
        sessions = try await sessionsResult
        persistentAgents = try await persistentResult
        cronJobs = try await cronResult
        approvalList = try await approvalsResult
        artifactList = try await artifactsResult
    }

    private func reconnect() async {
        let oldDeviceId = deviceId
        let oldToken = deviceToken
        do {
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            let pairing = try await client.startPairing()
            let completed = try await client.completePairing(code: pairing.code, deviceName: deviceName.isEmpty ? UIDevice.current.name : deviceName, platform: "ios")
            if !oldDeviceId.isEmpty {
                _ = try? await client.revokeDevice(id: oldDeviceId, deviceToken: oldToken)
            }
            deviceId = completed.deviceId
            deviceToken = completed.deviceToken
            KeychainHelper.save(completed.deviceId, key: "device_id")
            KeychainHelper.save(completed.deviceToken, key: "device_token")
            try await fetchAllData()
            statusMessage = "Reconnected to \(nodeName)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func createAgent() async {
        let name = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isLoadingPersistentAgents = true
        do {
            let client = makeClient()
            let agent = try await client.createPersistentAgent(name: name, description: newAgentDesc, deviceToken: deviceToken)
            persistentAgents.insert(agent, at: 0)
            newAgentName = ""
            newAgentDesc = ""
            toast = ToastMessage(text: "Created \(agent.name)", kind: .success)
        } catch {
            toast = ToastMessage(text: error.localizedDescription, kind: .error)
        }
        isLoadingPersistentAgents = false
    }

    private func deleteAgent(_ agent: PersistentAgent) async {
        do {
            let client = makeClient()
            try await client.deletePersistentAgent(id: agent.id, deviceToken: deviceToken)
            persistentAgents.removeAll { $0.id == agent.id }
            toast = ToastMessage(text: "Deleted \(agent.name)", kind: .success)
        } catch {
            toast = ToastMessage(text: error.localizedDescription, kind: .error)
        }
    }

    private func updatePersistentAgent() async {
        let name = editAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isLoadingPersistentAgents = true
        do {
            let client = makeClient()
            let updated = try await client.updatePersistentAgent(id: editAgentId, name: name, description: editAgentDesc, icon: editAgentIcon, deviceToken: deviceToken)
            if let idx = persistentAgents.firstIndex(where: { $0.id == editAgentId }) {
                persistentAgents[idx] = updated
            }
            isShowingEditAgent = false
            toast = ToastMessage(text: "Updated \(updated.name)", kind: .success)
        } catch {
            toast = ToastMessage(text: error.localizedDescription, kind: .error)
        }
        isLoadingPersistentAgents = false
    }

    private func loadAgentMessages(_ agent: PersistentAgent) async {
        isLoadingAgentMessages = true
        do {
            let client = makeClient()
            agentMessages = try await client.agentMessages(agentId: agent.id, deviceToken: deviceToken)
        } catch {
            statusMessage = error.localizedDescription
        }
        isLoadingAgentMessages = false
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
            let client = makeClient()
            let response = try await client.sendAgentMessage(agentId: agent.id, content: text, deviceToken: deviceToken)
            if let idx = agentMessages.firstIndex(where: { $0.id == localUserMsg.id }) {
                agentMessages[idx] = response.userMessage
            } else {
                agentMessages.append(response.userMessage)
            }
            agentMessages.append(response.assistantMessage)
        } catch {
            toast = ToastMessage(text: error.localizedDescription, kind: .error)
        }
        isSendingAgentMessage = false
    }

    private func addAgent() async {
        let name = agentNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = normalized(agentUrlDraft)
        guard !name.isEmpty, !url.isEmpty else { return }
        isAddingAgent = true
        do {
            let client = makeClient()
            let agent = try await client.addAgent(name: name, baseURL: url, deviceToken: deviceToken)
            agents.append(agent)
            agentNameDraft = ""
            agentUrlDraft = ""
            statusMessage = "Added \(agent.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
        isAddingAgent = false
    }

    private func updateAgentServer() async {
        guard let server = selectedAgentServer else { return }
        let name = editServerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = editServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isAddingAgent = true
        do {
            let client = makeClient()
            let updated = try await client.updateAgent(id: server.id, name: name, baseURL: url, deviceToken: deviceToken)
            if let idx = agents.firstIndex(where: { $0.id == server.id }) {
                agents[idx] = updated
            }
            selectedAgentServer = updated
            isShowingEditServer = false
            statusMessage = "Updated \(updated.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
        isAddingAgent = false
    }

    private func removeAgent(_ agent: AgentInfo) async {
        removingAgentId = agent.id
        do {
            let client = makeClient()
            try await client.removeAgent(id: agent.id, deviceToken: deviceToken)
            agents.removeAll { $0.id == agent.id }
            statusMessage = "Removed \(agent.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
        removingAgentId = nil
    }

    private func createNewSession() async {
        let goal = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        isCreatingSession = true
        do {
            let client = makeClient()
            let response = try await client.createSession(goal: goal, deviceToken: deviceToken)
            sessions.removeAll { $0.id == response.session.id }
            sessions.insert(response.session, at: 0)
            selectedSection = "Sessions"
            toast = ToastMessage(text: "Started \(response.session.title)", kind: .success)
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
            let client = makeClient()
            selectedTimeline = try await client.timeline(sessionId: session.id, deviceToken: deviceToken)
        } catch {
            selectedTimeline = nil
            timelineError = error.localizedDescription
        }
        isLoadingTimeline = false
    }

    private func appendGoal(to session: SessionSummary) async {
        let text = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAppendingGoal = true
        timelineError = ""
        do {
            let client = makeClient()
            let response = try await client.appendGoal(sessionId: session.id, text: text, deviceToken: deviceToken)
            selectedTimeline = response.timeline
            sessions.removeAll { $0.id == response.session.id }
            sessions.insert(response.session, at: 0)
            followUpDraft = ""
        } catch {
            timelineError = error.localizedDescription
            toast = ToastMessage(text: error.localizedDescription, kind: .error)
        }
        isAppendingGoal = false
    }

    private func makeClient() -> MobileGatewayClient {
        let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
        client.onUnauthorized = {
            await self.reconnect()
        }
        return client
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
        agents = []
        nodeName = ""
        statusMessage = "Disconnected"
    }
}

private enum NexusStyle {
    static let background = Color(red: 0.965, green: 0.976, blue: 0.992)
    static let card = Color.white.opacity(0.86)
    static let row = Color(red: 0.975, green: 0.981, blue: 0.992)
    static let selected = Color(red: 0.86, green: 0.902, blue: 0.978)
    static let line = Color(red: 0.87, green: 0.895, blue: 0.94)
    static let border = Color(red: 0.80, green: 0.842, blue: 0.91)
    static let blue = Color(red: 0.03, green: 0.345, blue: 0.94)
    static let green = Color(red: 0.12, green: 0.56, blue: 0.34)
    static let text = Color(red: 0.18, green: 0.19, blue: 0.22)
    static let muted = Color(red: 0.47, green: 0.49, blue: 0.54)
    static let subtleText = Color(red: 0.66, green: 0.68, blue: 0.73)
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
