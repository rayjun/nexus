import SwiftUI

/// General settings — Servers entry + independent rows (no section headers,
/// no bots here; bot management lives on the chat list rows).
struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @EnvironmentObject private var relay: RelayClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nexus_theme_light") private var lightTheme = true

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ServersView(store: store)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Servers").font(.system(size: 15, weight: .medium))
                            Text("\(relay.servers.filter { $0.isOnline }.count) connected · pair & manage")
                                .font(.system(size: 12)).foregroundStyle(NexusStyle.muted)
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                            .foregroundStyle(NexusStyle.blue)
                    }
                }
                Toggle(isOn: $lightTheme) {
                    Label {
                        Text("Light theme").font(.system(size: 15, weight: .medium))
                    } icon: {
                        Image(systemName: "sun.max.fill")
                            .foregroundStyle(.orange)
                    }
                }
                NavigationLink {
                    Text("Approval notifications — coming with the approvals pane.")
                        .font(.system(size: 14)).foregroundStyle(NexusStyle.muted).padding()
                } label: {
                    Label {
                        Text("Notifications").font(.system(size: 15, weight: .medium))
                    } icon: {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
                NavigationLink {
                    Text("E2E keys live in the Keychain (ThisDeviceOnly). No plaintext leaves the device unencrypted.")
                        .font(.system(size: 14)).foregroundStyle(NexusStyle.muted).padding()
                } label: {
                    Label {
                        Text("Privacy & Security").font(.system(size: 15, weight: .medium))
                    } icon: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("About").font(.system(size: 15, weight: .medium))
                        Text("Nexus \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                            .font(.system(size: 12)).foregroundStyle(NexusStyle.muted)
                    }
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(NexusStyle.muted)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NexusStyle.muted)
                    }
                }
            }
        }
    }
}

/// Servers management — list, re-pair, and pair via top-right `+`.
struct ServersView: View {
    @ObservedObject var store: ChatStore
    @EnvironmentObject private var relay: RelayClient
    @State private var isPairing = false
    @State private var toast: ToastMessage?

    var body: some View {
        List {
            Section {
                ForEach(relay.servers) { server in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(server.isOnline ? NexusStyle.green : NexusStyle.subtleText)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(NexusStyle.text)
                            Text(server.relayURL)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(NexusStyle.muted)
                        }
                        Spacer()
                        if !server.isOnline {
                            Button("Re-pair") {
                                relay.removeServer(serverID: server.id)
                                isPairing = true
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NexusStyle.blue)
                        } else {
                            Text("Online").font(.system(size: 12))
                                .foregroundStyle(NexusStyle.green)
                        }
                    }
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        let sid = relay.servers[idx].id
                        relay.removeServer(serverID: sid)
                        store.pruneServer(sid)
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Deleting a server keeps your bots on the phone as offline; re-pairing restores them.")
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPairing = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NexusStyle.blue)
                }
            }
        }
        .sheet(isPresented: $isPairing) {
            PairingView()
                .environmentObject(relay)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RelayPaired"))) { _ in
            Task { await store.refreshRoster() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RelayPairingFailed"))) { note in
            let msg = (note.userInfo?["message"] as? String) ?? "Pairing failed"
            toast = ToastMessage(text: msg, kind: .error)
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastView(message: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            await MainActor.run { self.toast = nil }
                        }
                    }
            }
        }
    }
}


/// Manage one bot from the chat list: rename (profiles.configure) and
/// delete-from-list (local tombstone — profiles.delete has no RPC).
struct BotManageSheet: View {
    @ObservedObject var store: ChatStore
    let bot: Bot
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String = ""
    @State private var isRenaming = false
    @State private var errorText = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Bot") {
                    LabeledContent("Profile", value: bot.name)
                    LabeledContent("Server", value: bot.serverID)
                    TextField("Display name", text: $displayName)
                    LabeledContent("Model", value: bot.model.isEmpty ? "server default" : bot.model)
                }
                Section("Session") {
                    LabeledContent("Thread", value: bot.preferredSessionID ?? "none yet")
                    LabeledContent("Last active", value: bot.lastActiveAt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "—")
                }
                if !errorText.isEmpty {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button("Delete from list", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("This hides the bot on this phone. The Hermes profile stays on the server.")
                }
            }
            .navigationTitle(bot.displayTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await rename() } }
                        .disabled(isRenaming || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Delete \"\(bot.displayTitle)\" from this list?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    store.tombstoneBot(bot)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { displayName = bot.displayName }
    }

    private func rename() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != bot.displayName else { dismiss(); return }
        isRenaming = true
        defer { isRenaming = false }
        do {
            try await store.renameBot(bot, displayName: trimmed)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
