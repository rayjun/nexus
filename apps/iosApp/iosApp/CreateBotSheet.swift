import SwiftUI

/// Create a bot on a paired server — one bot = one Hermes profile.
/// slug validated client-side with the same regex as the Hermes web UI;
/// mirror_credentials is NEVER sent (least privilege, and the server
/// seeds credentials by default anyway).
struct CreateBotSheet: View {
    @ObservedObject var store: ChatStore
    @EnvironmentObject private var relay: RelayClient
    var onCreated: ((Bot) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var slug = ""
    @State private var displayName = ""
    @State private var descriptor = ""
    @State private var soul = ""
    @State private var selectedServerID = ""
    @State private var selectedModel = ""
    @State private var isSaving = false
    @State private var errorText = ""

    private let modelOptions = ["", "glm-5.2", "gpt-5", "claude-4", "deepseek-v4-flash"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Bot") {
                    TextField("name (slug)", text: $slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: slug) { _ in
                            slug = String(slug.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
                        }
                    TextField("Display name (optional)", text: $displayName)
                    TextField("Description (optional)", text: $descriptor, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Model", selection: $selectedModel) {
                        Text("Server default").tag("")
                        ForEach(modelOptions.filter { !$0.isEmpty }, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                }
                Section("Server") {
                    Picker("Server", selection: $selectedServerID) {
                        Text("Select a server").tag("")
                        ForEach(relay.servers) { s in
                            Label(s.name, systemImage: s.isOnline ? "circle.fill" : "circle")
                                .tag(s.id)
                        }
                    }
                }
                Section {
                    Text("Personality (SOUL.md, optional)")
                        .font(.footnote).foregroundStyle(NexusStyle.subtleText)
                    TextEditor(text: $soul)
                        .frame(minHeight: 80)
                        .font(.system(size: 13, design: .monospaced))
                } footer: {
                    Text("Each bot is a Hermes profile with its own model, memory and settings.")
                }
                if !errorText.isEmpty {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("New bot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(!canCreate || isSaving)
                }
            }
        }
        .onAppear {
            if selectedServerID.isEmpty {
                selectedServerID = relay.servers.first?.id ?? ""
            }
        }
    }

    private var canCreate: Bool {
        Bot.isValidSlug(slug) && !selectedServerID.isEmpty
    }

    private func create() async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        defer { isSaving = false }
        do {
            let bot = try await store.createBot(
                serverID: selectedServerID,
                name: slug.lowercased(),
                description: trimmedDesc,
                soul: soul,
                model: selectedModel
            )
            if !trimmedName.isEmpty {
                let renamed = bot.displayName == bot.name
                if renamed {
                    do { try await store.renameBot(bot, displayName: trimmedName) } catch {}
                }
            }
            dismiss()
            onCreated?(bot)
        } catch {
            errorText = error.localizedDescription
        }
    }
}