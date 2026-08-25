import SwiftUI

/// Home — the bot roster as a clean chat list (Grok/TG style, user-approved).
/// Server truth via ChatStore.refreshRoster(); rows are flat, no wordmark,
/// no status row. Search (top-left), + new bot, ⚙ settings.
struct ChatListView: View {
    @ObservedObject var store: ChatStore
    @EnvironmentObject private var relay: RelayClient

    @State private var searchText = ""
    @State private var isSearchActive = false
    @FocusState private var searchFocused: Bool
    @State private var isShowingCreate = false
    @State private var isShowingSettings = false
    @State private var selectedBot: Bot?
    @State private var botToManage: Bot?
    @State private var toast: ToastMessage?

    private var visibleBots: [Bot] {
        let all = store.bots.filter { !$0.isTombstoned }
        guard !searchText.isEmpty else { return all }
        return all.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.serverID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NexusStyle.background.ignoresSafeArea()
                content
                if let toast {
                    ToastView(message: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(100)
                        .onAppear {
                            Task {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                await MainActor.run { self.toast = nil }
                            }
                        }
                }
            }
            .navigationBarHidden(true)
            .task { await store.refreshRoster() }
        }
        .onChange(of: relay.isConnected) { connected in
            if connected { Task { await store.refreshRoster() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RelayPaired"))) { _ in
            Task { await store.refreshRoster() }
        }
        .fullScreenCover(item: $selectedBot) { bot in
            ChatView(bot: bot, store: store)
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateBotSheet(store: store) { bot in
                selectedBot = bot
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(store: store)
        }
        .sheet(item: $botToManage) { bot in
            BotManageSheet(store: store, bot: bot)
        }
    }

    @ViewBuilder
    private var content: some View {
        if relay.servers.isEmpty {
            emptyNoServers
        } else if store.bots.filter({ !$0.isTombstoned }).isEmpty {
            emptyNoBots
        } else {
            VStack(spacing: 0) {
                topBar
                if !searchText.isEmpty || !store.bots.isEmpty {
                    rosterList
                }
            }
        }
    }

    /// Two states: idle (search icon + create + settings) and searching
    /// (field + Cancel) — the search field only appears after tapping the
    /// magnifier (TG-style), never before.
    private var topBar: some View {
        Group {
            if isSearchActive {
                searchBar
            } else {
                idleBar
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.18), value: isSearchActive)
    }

    private var idleBar: some View {
        HStack(spacing: 16) {
            Button {
                isSearchActive = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NexusStyle.text)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                isShowingCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(NexusStyle.blue)
            }
            .buttonStyle(.plain)
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NexusStyle.muted)
            }
            .buttonStyle(.plain)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NexusStyle.subtleText)
            TextField("Search bots", text: $searchText)
                .font(.system(size: 15))
                .foregroundStyle(NexusStyle.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(NexusStyle.subtleText)
                }
                .buttonStyle(.plain)
            }
            Button("Cancel") {
                searchText = ""
                isSearchActive = false
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(NexusStyle.blue)
            .buttonStyle(.plain)
        }
        .onAppear { searchFocused = true }
    }

    private var rosterList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleBots) { bot in
                    botRow(bot)
                    Divider().overlay(NexusStyle.border.opacity(0.5))
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refreshRoster() }
        .overlay {
            if visibleBots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30)).foregroundStyle(NexusStyle.subtleText)
                    Text("No bots match \"\(searchText)\"")
                        .font(.system(size: 14)).foregroundStyle(NexusStyle.muted)
                }
            }
        }
    }

    private func botRow(_ bot: Bot) -> some View {
        Button {
            selectedBot = bot
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(avatarColor(bot)).frame(width: 46, height: 46)
                    Text(String(bot.displayTitle.prefix(1)).uppercased())
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(bot.displayTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NexusStyle.text)
                            .lineLimit(1)
                        if !bot.model.isEmpty {
                            Text(bot.model)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(NexusStyle.muted)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(NexusStyle.border.opacity(0.35), in: Capsule())
                        }
                        Spacer(minLength: 4)
                        if let t = bot.lastActiveAt {
                            Text(timeString(t))
                                .font(.system(size: 11))
                                .foregroundStyle(NexusStyle.subtleText)
                        }
                    }
                    HStack(spacing: 5) {
                        Circle().fill(bot.status == .offline ? NexusStyle.subtleText : NexusStyle.green)
                            .frame(width: 7, height: 7)
                        Text(bot.lastPreview ?? (bot.status == .offline ? "Offline — re-pair in Settings" : "Start chatting"))
                            .font(.system(size: 13))
                            .foregroundStyle(bot.status == .offline ? NexusStyle.muted : NexusStyle.muted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                botToManage = bot
            } label: { Label("Rename / Info", systemImage: "slider.horizontal.3") }
            Button(role: .destructive) {
                store.tombstoneBot(bot)
                toast = ToastMessage(text: "\"\(bot.displayTitle)\" hidden (profile kept on server)", kind: .info)
            } label: { Label("Delete from list", systemImage: "trash") }
        }
    }

    private func avatarColor(_ bot: Bot) -> Color {
        // Stable hue from the slug — no extra state.
        let names = ["blue", "purple", "green", "orange", "pink", "indigo"]
        let v = bot.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        switch names[v % names.count] {
        case "purple": return Color(red: 0.55, green: 0.36, blue: 0.98)
        case "green": return Color(red: 0.13, green: 0.78, blue: 0.45)
        case "orange": return Color(red: 0.96, green: 0.62, blue: 0.12)
        case "pink": return Color(red: 0.9, green: 0.35, blue: 0.6)
        case "indigo": return Color(red: 0.35, green: 0.45, blue: 0.95)
        default: return NexusStyle.blue
        }
    }

    private func timeString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var emptyNoServers: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 40)).foregroundStyle(NexusStyle.subtleText)
            Text("No servers yet")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(NexusStyle.muted)
            Text("Pair a server to start chatting")
                .font(.system(size: 14)).foregroundStyle(NexusStyle.muted)
            Button {
                isShowingSettings = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                    Text("Pair Server")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20).frame(height: 44)
                .background(NexusStyle.blue, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyNoBots: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.waveform")
                .font(.system(size: 40)).foregroundStyle(NexusStyle.subtleText)
            Text("No bots yet")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(NexusStyle.muted)
            Text("Tap + to create your first bot — one bot per Hermes profile")
                .font(.system(size: 14)).foregroundStyle(NexusStyle.muted)
                .multilineTextAlignment(.center)
            Button {
                isShowingCreate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Create bot")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20).frame(height: 44)
                .background(NexusStyle.blue, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }
}