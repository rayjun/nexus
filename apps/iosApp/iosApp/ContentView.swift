import SwiftUI

struct ContentView: View {
    @AppStorage("gateway_base_url") private var gatewayBaseUrl = "http://127.0.0.1:8765"
    @AppStorage("device_id") private var deviceId = ""
    @AppStorage("device_token") private var deviceToken = ""
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
    @State private var isLoadingAgents2 = false
    @State private var isLoadingAgentMessages = false
    @State private var agentInputDraft = ""
    @State private var isSendingAgentMessage = false
    @State private var isShowingCreateAgent = false
    @State private var newAgentName = ""
    @State private var newAgentDesc = ""

    private var isConnected: Bool {
        !deviceId.isEmpty && !deviceToken.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HermesMobileStyle.background.ignoresSafeArea()
                if isConnected {
                    appHome
                } else {
                    connectView
                }
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            gatewayInput = gatewayBaseUrl
            if isConnected {
                Task { await loadHome() }
            } else if ProcessInfo.processInfo.environment["HERMES_MOBILE_AUTOCONNECT"] == "1" {
                Task { await connect() }
            }
        }
        .sheet(isPresented: $isShowingComposer) {
            goalComposer
        }
        .sheet(isPresented: $isShowingCreateAgent) {
            createAgentSheet
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
                mobileTopBar(title: "Hermes Mobile", subtitle: "Gateway Control Surface")

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        iconTile("bolt.horizontal.circle.fill")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connect to Hermes")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(HermesMobileStyle.text)
                            Text("Pair this iPhone with your local Hermes gateway.")
                                .font(.system(size: 14))
                                .foregroundStyle(HermesMobileStyle.muted)
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
                            Text("⌘↩")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(HermesMobileStyle.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isConnecting || normalized(gatewayInput).isEmpty)

                    if !statusMessage.isEmpty {
                        statusPill(text: statusMessage, positive: statusMessage.hasPrefix("Connected"))
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("SETUP FLOW", count: 3)
                    capabilityRow(icon: "checkmark.circle", title: "Probe gateway", subtitle: "GET /mobile/v1/status", active: true)
                    capabilityRow(icon: "number.circle", title: "Create pairing code", subtitle: "POST /mobile/v1/pair/start", active: true)
                    capabilityRow(icon: "lock.circle", title: "Store device token", subtitle: "Local AppStorage for MVP", active: true)
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
                        .foregroundStyle(HermesMobileStyle.blue)
                    }
                    .buttonStyle(.plain)
                    mobileTopBar(title: agent.name, subtitle: agent.baseUrl)
                    statusStrip
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
                    Text("Hermes")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(HermesMobileStyle.text)
                    Spacer()
                    Button {
                        Task { await loadHome() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(HermesMobileStyle.muted)
                    }
                    .buttonStyle(.plain)
                    Button {
                        agentNameDraft = ""
                        agentUrlDraft = ""
                        isShowingAddServer = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(HermesMobileStyle.blue)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(HermesMobileStyle.blue)
                        .frame(width: 7, height: 7)
                    Text("\(agents.filter { $0.status == "online" }.count) of \(agents.count) servers online")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(HermesMobileStyle.muted)
                }

                if isLoadingAgents {
                    loadingRows
                        .padding(.horizontal, 2)
                } else if agents.isEmpty {
                    VStack(alignment: .center, spacing: 14) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 40))
                            .foregroundStyle(HermesMobileStyle.subtleText)
                        Text("No servers yet")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(HermesMobileStyle.muted)
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
                            .background(HermesMobileStyle.blue, in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(agents) { agent in
                        agentServerCard(agent)
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
        .background(HermesMobileStyle.background)
        .sheet(isPresented: $isShowingAddServer) {
            addServerSheet
        }
    }

    private var addServerSheet: some View {
        NavigationStack {
            ZStack {
                HermesMobileStyle.background.ignoresSafeArea()
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
                        HStack {
                            if isAddingAgent {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                            Text(isAddingAgent ? "Adding" : "Add server")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(canAddAgent ? HermesMobileStyle.blue : HermesMobileStyle.subtleText, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .disabled(!canAddAgent || isAddingAgent)
                }
                .padding(18)
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowingAddServer = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            statusChip(icon: "checkmark", text: "Gateway", color: HermesMobileStyle.green)
            statusChip(icon: "sparkles", text: "Agents", color: HermesMobileStyle.text)
            statusChip(icon: "clock", text: "Cron", color: HermesMobileStyle.text)
        }
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
                                .fill(selectedSection == item ? HermesMobileStyle.blue : HermesMobileStyle.subtleText)
                                .frame(width: 6, height: 6)
                            Text(item.uppercased())
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(1.8)
                        }
                        .foregroundStyle(selectedSection == item ? HermesMobileStyle.blue : HermesMobileStyle.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(selectedSection == item ? HermesMobileStyle.selected : .white.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
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
                if isLoadingAgents2 {
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
            placeholderPanel(title: "CRON JOBS", icon: "clock", rows: [("mind-github-sync", "in 41 min."), ("hermes-memory-sync", "in 41 min.")])
        case "Artifacts":
            placeholderPanel(title: "ARTIFACTS", icon: "doc", rows: [("No artifacts yet", "Files and generated outputs will land here")])
        default:
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("INBOX", count: 2)
                inboxRow(icon: "terminal", title: "Approvals", subtitle: "No pending approval requests", tint: HermesMobileStyle.green)
                inboxRow(icon: "bubble.left.and.bubble.right", title: "Messages", subtitle: "Gateway connected and listening", tint: HermesMobileStyle.blue)
                Button("Refresh sessions") {
                    selectedSection = "Sessions"
                    Task { await loadHome() }
                }
                .font(.system(size: 14, weight: .medium))
                .buttonStyle(.bordered)
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
                        .fill(isOnline ? HermesMobileStyle.blue.opacity(0.12) : HermesMobileStyle.line.opacity(0.5))
                        .frame(width: 48, height: 48)
                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isOnline ? HermesMobileStyle.blue : HermesMobileStyle.subtleText)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(HermesMobileStyle.text)
                    Text(agent.baseUrl)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(HermesMobileStyle.muted)
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
                        .fill(isOnline ? HermesMobileStyle.blue : HermesMobileStyle.subtleText)
                        .frame(width: 6, height: 6)
                    Text(isOnline ? "Online" : "Offline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isOnline ? HermesMobileStyle.blue : HermesMobileStyle.subtleText)
                }
                Text("·")
                    .foregroundStyle(HermesMobileStyle.subtleText)
                Text(agent.profile)
                    .font(.system(size: 12))
                    .foregroundStyle(HermesMobileStyle.muted)
                Text("·")
                    .foregroundStyle(HermesMobileStyle.subtleText)
                Text(agent.model)
                    .font(.system(size: 12))
                    .foregroundStyle(HermesMobileStyle.muted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HermesMobileStyle.subtleText)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            selectedAgentServer = agent
        }
    }

    private var loadingRows: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(HermesMobileStyle.line.opacity(0.55))
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
                        .fill(HermesMobileStyle.blue.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(HermesMobileStyle.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HermesMobileStyle.text)
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.system(size: 12))
                            .foregroundStyle(HermesMobileStyle.muted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text("\(agent.capabilities.count) capabilities")
                            .font(.system(size: 11))
                            .foregroundStyle(HermesMobileStyle.subtleText)
                        Text("·")
                            .foregroundStyle(HermesMobileStyle.subtleText)
                        Text("\(agent.linkedSessionIds.count) sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(HermesMobileStyle.subtleText)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HermesMobileStyle.subtleText)
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
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
                HermesMobileStyle.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    desktopField(title: "AGENT NAME", text: $newAgentName, placeholder: "Code Reviewer", systemImage: "sparkles")
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.alignleft")
                            Text("DESCRIPTION")
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.7)
                        .foregroundStyle(HermesMobileStyle.blue)
                        TextField("What does this agent do?", text: $newAgentDesc, axis: .vertical)
                            .font(.system(size: 15))
                            .foregroundStyle(HermesMobileStyle.text)
                            .textInputAutocapitalization(.sentences)
                            .lineLimit(1...3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
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
                        HStack {
                            if isLoadingAgents2 {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(isLoadingAgents2 ? "Creating" : "Create agent")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(!newAgentName.isEmpty ? HermesMobileStyle.blue : HermesMobileStyle.subtleText, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .disabled(newAgentName.isEmpty || isLoadingAgents2)
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
                            .foregroundStyle(HermesMobileStyle.muted)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func agentConversationView(_ agent: PersistentAgent) -> some View {
        ZStack {
            HermesMobileStyle.background.ignoresSafeArea()
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
                                                    .foregroundStyle(HermesMobileStyle.blue)
                                                Text(cap)
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(HermesMobileStyle.muted)
                                            }
                                        }
                                    }
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HermesMobileStyle.subtleText)
                                .tint(HermesMobileStyle.subtleText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(HermesMobileStyle.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            if isLoadingAgentMessages {
                                loadingRows
                            } else if agentMessages.isEmpty {
                                emptyState(title: "No messages yet", subtitle: "Send a message to start chatting with this agent.")
                                    .padding(.top, 40)
                            } else {
                                ForEach(agentMessages) { msg in
                                    agentChatBubble(msg)
                                        .id(msg.id)
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
                    .onAppear {
                        if let lastId = agentMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
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
                    Text("Agents")
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
        return HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(text: msg.content, textColor: isUser ? .white : HermesMobileStyle.text)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                isUser ? HermesMobileStyle.blue : .white,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isUser ? Color.clear : HermesMobileStyle.border, lineWidth: 1)
            )
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func agentInputBar(_ agent: PersistentAgent) -> some View {
        HStack(spacing: 10) {
            TextField("Message \(agent.name)…", text: $agentInputDraft, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(HermesMobileStyle.text)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(HermesMobileStyle.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
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
            .background(!agentInputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSendingAgentMessage ? HermesMobileStyle.subtleText : HermesMobileStyle.blue, in: Circle())
            .disabled(agentInputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingAgentMessage)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.94))
        .overlay(Rectangle().fill(HermesMobileStyle.border).frame(height: 1), alignment: .top)
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
                    .foregroundStyle(HermesMobileStyle.blue)
                Text("Start with an agent")
                    .font(.system(size: 16))
                    .foregroundStyle(HermesMobileStyle.muted)
                Spacer()
                Circle()
                    .fill(HermesMobileStyle.blue)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(.white.opacity(0.92))
        .overlay(Rectangle().fill(HermesMobileStyle.border).frame(height: 1), alignment: .top)
    }

    private var goalComposer: some View {
        NavigationStack {
            ZStack {
                HermesMobileStyle.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NEW SESSION")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(HermesMobileStyle.blue)
                        Text("Start with a goal")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(HermesMobileStyle.text)
                        Text("Create a new Hermes session. The agent will run from the connected gateway, not on this device.")
                            .font(.system(size: 14))
                            .foregroundStyle(HermesMobileStyle.muted)
                    }

                    TextEditor(text: $goalDraft)
                        .font(.system(size: 17))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 170)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            if goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Describe the outcome you want Hermes to achieve…")
                                    .font(.system(size: 17))
                                    .foregroundStyle(HermesMobileStyle.subtleText)
                                    .padding(.horizontal, 17)
                                    .padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: 8) {
                        statusChip(icon: "server.rack", text: nodeName.isEmpty ? "Hermes" : nodeName, color: HermesMobileStyle.text)
                        statusChip(icon: "network", text: "Gateway", color: HermesMobileStyle.green)
                    }

                    Spacer()

                    Button {
                        Task { await createNewSession() }
                    } label: {
                        HStack {
                            if isCreatingSession {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                            }
                            Text(isCreatingSession ? "Starting" : "Start session")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(canCreateSession ? HermesMobileStyle.blue : HermesMobileStyle.subtleText, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .disabled(!canCreateSession || isCreatingSession)
                }
                .padding(18)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowingComposer = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sessionDetail(_ session: SessionSummary) -> some View {
        ZStack {
            HermesMobileStyle.background.ignoresSafeArea()
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
                    Text("Sessions")
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
                .foregroundStyle(HermesMobileStyle.text)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(HermesMobileStyle.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
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
            .background(canAppendGoal ? HermesMobileStyle.text : HermesMobileStyle.subtleText, in: Circle())
            .disabled(!canAppendGoal || isAppendingGoal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.94))
        .overlay(Rectangle().fill(HermesMobileStyle.border).frame(height: 1), alignment: .top)
    }

    private var canAppendGoal: Bool {
        !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !deviceToken.isEmpty
    }

    private func chatBubble(_ item: TimelineItem) -> some View {
        let isUser = item.type == "user_goal"
        let isThinking = item.type == "thinking_block"
        let body = item.text ?? item.markdown ?? ""

        return HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 40) }

            if isThinking {
                DisclosureGroup("Thinking") {
                    if !body.isEmpty {
                        MarkdownText(text: body, textColor: HermesMobileStyle.subtleText)
                    }
                    if let calls = item.toolCalls, !calls.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(calls.prefix(6)) { call in
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(call.status == "failed" ? .red : HermesMobileStyle.subtleText)
                                        .frame(width: 4, height: 4)
                                    Text(call.summary)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(HermesMobileStyle.subtleText)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(HermesMobileStyle.subtleText)
                .tint(HermesMobileStyle.subtleText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(HermesMobileStyle.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if body.isEmpty {
                        Text(timelineTitle(item))
                            .font(.system(size: 15))
                            .foregroundStyle(isUser ? .white : HermesMobileStyle.text)
                    } else {
                        MarkdownText(text: body, textColor: isUser ? .white : HermesMobileStyle.text)
                    }

                    if let calls = item.toolCalls, !calls.isEmpty {
                        DisclosureGroup("Tool calls (\(calls.count))") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(calls.prefix(8)) { call in
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(call.status == "failed" ? .red : (call.status == "running" ? HermesMobileStyle.blue : HermesMobileStyle.subtleText))
                                            .frame(width: 5, height: 5)
                                        Text(call.summary)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(call.status == "failed" ? .red : HermesMobileStyle.muted)
                                            .lineLimit(2)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HermesMobileStyle.subtleText)
                        .tint(HermesMobileStyle.subtleText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    isUser ? HermesMobileStyle.blue : .white,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isUser ? Color.clear : HermesMobileStyle.border, lineWidth: 1)
                )
            }

            if !isUser && !isThinking { Spacer(minLength: 40) }
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

    private func mobileTopBar(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(HermesMobileStyle.selected)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: "rectangle.split.2x1").foregroundStyle(HermesMobileStyle.muted))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(HermesMobileStyle.text)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(HermesMobileStyle.muted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundStyle(HermesMobileStyle.muted)
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
            .foregroundStyle(HermesMobileStyle.blue)
            TextField(placeholder, text: text)
                .font(.system(size: 15))
                .foregroundStyle(HermesMobileStyle.text)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
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
                .foregroundStyle(HermesMobileStyle.subtleText)
            Spacer()
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(HermesMobileStyle.blue)
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.status == "running" ? HermesMobileStyle.green : HermesMobileStyle.subtleText)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HermesMobileStyle.text)
                    .lineLimit(1)
                Text(session.status)
                    .font(.system(size: 12))
                    .foregroundStyle(HermesMobileStyle.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HermesMobileStyle.subtleText)
        }
        .padding(12)
        .background(HermesMobileStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func inboxRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HermesMobileStyle.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(HermesMobileStyle.muted)
            }
            Spacer()
        }
        .padding(12)
        .background(HermesMobileStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func capabilityRow(icon: String, title: String, subtitle: String, active: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(active ? HermesMobileStyle.blue : HermesMobileStyle.muted)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HermesMobileStyle.text)
                Text(subtitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(HermesMobileStyle.muted)
            }
            Spacer()
        }
        .padding(10)
        .background(HermesMobileStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func placeholderPanel(title: String, icon: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, count: rows.count)
            ForEach(rows, id: \.0) { row in
                inboxRow(icon: icon, title: row.0, subtitle: row.1, tint: HermesMobileStyle.blue)
            }
        }
        .cardStyle()
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HermesMobileStyle.text)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(HermesMobileStyle.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(HermesMobileStyle.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .overlay(Capsule().stroke(HermesMobileStyle.border, lineWidth: 1))
    }

    private func statusPill(text: String, positive: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(positive ? HermesMobileStyle.green : HermesMobileStyle.subtleText)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(positive ? HermesMobileStyle.green : HermesMobileStyle.muted)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(HermesMobileStyle.row, in: Capsule())
    }

    private func iconTile(_ systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(HermesMobileStyle.selected)
            .frame(width: 48, height: 48)
            .overlay(Image(systemName: systemName).font(.system(size: 24)).foregroundStyle(HermesMobileStyle.blue))
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
        isLoadingAgents2 = true
        do {
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            nodeName = try await client.status().nodeName
            agents = try await client.agents(deviceToken: deviceToken)
            sessions = try await client.sessions(deviceToken: deviceToken)
            persistentAgents = try await client.persistentAgents(deviceToken: deviceToken)
        } catch MobileGatewayError.badStatus(401) {
            statusMessage = "Reconnecting..."
            await reconnect()
            isLoadingAgents = false
            isLoadingSessions = false
            isLoadingAgents2 = false
            return
        } catch {
            statusMessage = error.localizedDescription
        }
        isLoadingAgents = false
        isLoadingSessions = false
        isLoadingAgents2 = false
    }

    private func reconnect() async {
        do {
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            let pairing = try await client.startPairing()
            let completed = try await client.completePairing(code: pairing.code, deviceName: deviceName.isEmpty ? UIDevice.current.name : deviceName, platform: "ios")
            deviceId = completed.deviceId
            deviceToken = completed.deviceToken
            nodeName = try await client.status().nodeName
            agents = try await client.agents(deviceToken: deviceToken)
            sessions = try await client.sessions(deviceToken: deviceToken)
            persistentAgents = try await client.persistentAgents(deviceToken: deviceToken)
            statusMessage = "Reconnected to \(nodeName)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func createAgent() async {
        let name = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isLoadingAgents2 = true
        do {
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            let agent = try await client.createPersistentAgent(name: name, description: newAgentDesc, deviceToken: deviceToken)
            persistentAgents.insert(agent, at: 0)
            newAgentName = ""
            newAgentDesc = ""
            statusMessage = "Created \(agent.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
        isLoadingAgents2 = false
    }

    private func deleteAgent(_ agent: PersistentAgent) async {
        do {
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            try await client.deletePersistentAgent(id: agent.id, deviceToken: deviceToken)
            persistentAgents.removeAll { $0.id == agent.id }
            statusMessage = "Deleted \(agent.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadAgentMessages(_ agent: PersistentAgent) async {
        isLoadingAgentMessages = true
        do {
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            agentMessages = try await client.agentMessages(agentId: agent.id, deviceToken: deviceToken)
        } catch MobileGatewayError.badStatus(401) {
            await reconnect()
            do {
                let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
                agentMessages = try await client.agentMessages(agentId: agent.id, deviceToken: deviceToken)
            } catch {
                statusMessage = error.localizedDescription
            }
        } catch {
            statusMessage = error.localizedDescription
        }
        isLoadingAgentMessages = false
    }

    private func sendAgentMsg(_ agent: PersistentAgent) async {
        let text = agentInputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSendingAgentMessage = true
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
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            let response = try await client.sendAgentMessage(agentId: agent.id, content: text, deviceToken: deviceToken)
            if let idx = agentMessages.firstIndex(where: { $0.id == localUserMsg.id }) {
                agentMessages[idx] = response.userMessage
            } else {
                agentMessages.append(response.userMessage)
            }
            agentMessages.append(response.assistantMessage)
        } catch MobileGatewayError.badStatus(401) {
            await reconnect()
            do {
                let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
                let response = try await client.sendAgentMessage(agentId: agent.id, content: text, deviceToken: deviceToken)
                if let idx = agentMessages.firstIndex(where: { $0.id == localUserMsg.id }) {
                    agentMessages[idx] = response.userMessage
                } else {
                    agentMessages.append(response.userMessage)
                }
                agentMessages.append(response.assistantMessage)
            } catch {
                statusMessage = error.localizedDescription
            }
        } catch {
            statusMessage = error.localizedDescription
        }
        isSendingAgentMessage = false
    }

    private func addAgent() async {
        let name = agentNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = normalized(agentUrlDraft)
        guard !name.isEmpty, !url.isEmpty else { return }
        isAddingAgent = true
        do {
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
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

    private func removeAgent(_ agent: AgentInfo) async {
        removingAgentId = agent.id
        do {
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
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
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            let response = try await client.createSession(goal: goal, deviceToken: deviceToken)
            sessions.removeAll { $0.id == response.session.id }
            sessions.insert(response.session, at: 0)
            selectedSection = "Sessions"
            statusMessage = "Started \(response.session.title)"
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
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
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
            let client = MobileGatewayClient(baseURL: gatewayBaseUrl)
            let response = try await client.appendGoal(sessionId: session.id, text: text, deviceToken: deviceToken)
            selectedTimeline = response.timeline
            sessions.removeAll { $0.id == response.session.id }
            sessions.insert(response.session, at: 0)
            followUpDraft = ""
        } catch {
            timelineError = error.localizedDescription
        }
        isAppendingGoal = false
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func clearPairing() {
        deviceId = ""
        deviceToken = ""
        sessions = []
        agents = []
        nodeName = ""
        statusMessage = "Disconnected"
    }
}

private enum HermesMobileStyle {
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
            .background(HermesMobileStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(HermesMobileStyle.border, lineWidth: 1))
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
                case .codeBlock(let code):
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(textColor)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .heading(let level, let content):
                    Text(inlineAttributed(content))
                        .font(.system(size: level == 1 ? 20 : (level == 2 ? 17 : 15), weight: .bold))
                        .foregroundStyle(textColor)
                case .paragraph(let content):
                    Text(inlineAttributed(content))
                        .font(.system(size: 15))
                        .foregroundStyle(textColor)
                case .bullet(let content):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 15))
                            .foregroundStyle(textColor)
                        Text(inlineAttributed(content))
                            .font(.system(size: 15))
                            .foregroundStyle(textColor)
                    }
                }
            }
        }
    }

    private enum Block {
        case codeBlock(String)
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                result.append(.codeBlock(codeLines.joined(separator: "\n")))
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
                result.append(.bullet(String(line.dropFirst(2))))
                i += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
            } else {
                result.append(.paragraph(line))
                i += 1
            }
        }
        return result
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
            } else {
                result.append(AttributedString(remaining))
                remaining = ""
            }
        }
        return result
    }
}

#Preview {
    ContentView()
}
