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
            ScrollView {
                VStack(spacing: 12) {
                    settingsRow {
                        NavigationLink {
                            ServersView(store: store)
                        } label: {
                            rowContent("server.rack", title: "Servers",
                                       subtitle: "\(relay.servers.filter { $0.isOnline }.count) connected · pair & manage",
                                       tint: NexusStyle.blue, chevron: true)
                        }
                    }
                    settingsRow {
                        Toggle(isOn: $lightTheme) {
                            rowContent("sun.max.fill", title: "Light theme",
                                       subtitle: "Day theme is the default", tint: .orange, chevron: false)
                        }
                        .tint(NexusStyle.blue)
                    }
                    settingsRow {
                        NavigationLink {
                            Text("Approval notifications — coming with the approvals pane.")
                                .font(.system(size: 14)).foregroundStyle(NexusStyle.muted).padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            rowContent("bell.fill", title: "Notifications",
                                       subtitle: "Approvals, errors, mentions", tint: NexusStyle.muted, chevron: true)
                        }
                    }
                    settingsRow {
                        NavigationLink {
                            Text("E2E keys live in the Keychain (ThisDeviceOnly). No plaintext leaves the device unencrypted.")
                                .font(.system(size: 14)).foregroundStyle(NexusStyle.muted).padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            rowContent("lock.fill", title: "Privacy & Security",
                                       subtitle: "E2E keys in Keychain only", tint: NexusStyle.muted, chevron: true)
                        }
                    }
                    settingsRow {
                        rowContent("info.circle.fill", title: "About",
                                   subtitle: "Nexus \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")",
                                   tint: NexusStyle.muted, chevron: false)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(NexusStyle.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(NexusStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
    }

    private func rowContent(_ icon: String, title: String, subtitle: String,
                            tint: Color, chevron: Bool) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusStyle.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(NexusStyle.muted)
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NexusStyle.subtleText)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Servers management — list, re-pair, and pair via top-right `+`.
struct ServersView: View {
    @ObservedObject var store: ChatStore
    @EnvironmentObject private var relay: RelayClient
    @State private var isPairing = false
    @State private var toast: ToastMessage?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
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
                                // Drop the orphaned profile + its bots BEFORE
                                // re-pairing: removeServer generates a NEW server
                                // UUID, so without pruneServer the old server's
                                // bots would linger as ghosts (stale preview,
                                // tappable, misrouted).
                                relay.removeServer(serverID: server.id)
                                store.pruneServer(server.id)
                                isPairing = true
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NexusStyle.blue)
                        } else {
                            Text("Online").font(.system(size: 12))
                                .foregroundStyle(NexusStyle.green)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(NexusStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contextMenu {
                        Button("Delete server", role: .destructive) {
                            relay.removeServer(serverID: server.id)
                            store.pruneServer(server.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(NexusStyle.background)
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            infoRow("Profile", bot.name)
                            infoRow("Server", bot.serverID)
                            fieldLabel("Display name")
                            TextField(bot.name, text: $displayName)
                                .fieldInput()
                            infoRow("Model", bot.model.isEmpty ? "server default" : bot.model)
                        }
                    }

                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            infoRow("Thread", bot.preferredSessionID ?? "none yet")
                            infoRow("Last active", bot.lastActiveAt.map {
                                $0.formatted(date: .abbreviated, time: .shortened)
                            } ?? "—")
                        }
                    }

                    if !errorText.isEmpty {
                        Text(errorText).font(.system(size: 13)).foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }

                    Button("Delete from list", role: .destructive) { confirmDelete = true }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.red.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.red.opacity(0.25), lineWidth: 1))

                    Text("This hides the bot on this phone. The Hermes profile stays on the server.")
                        .font(.system(size: 12))
                        .foregroundStyle(NexusStyle.subtleText)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
            }
            .background(NexusStyle.background)
            .navigationTitle(bot.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
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

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(NexusStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NexusStyle.muted)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(NexusStyle.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(NexusStyle.muted)
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
