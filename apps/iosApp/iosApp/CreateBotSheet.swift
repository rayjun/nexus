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
    @State private var modelList: [String] = []
    @State private var isLoadingModels = false
    @State private var isSaving = false
    @State private var errorText = ""

    // Fallback when a server is offline or model.options fails.
    private let fallbackModels = ["glm-5.2", "gpt-5", "claude-4", "deepseek-v4-flash"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fieldGroup(title: "Bot") {
                        VStack(spacing: 14) {
                            fieldLabel("Name (slug)")
                            TextField("e.g. research-bot", text: $slug)
                                .fieldInput()
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: slug) { _ in
                                    slug = String(slug.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
                                }
                            fieldLabel("Display name (optional)")
                            TextField("Research Bot", text: $displayName)
                                .fieldInput()
                            fieldLabel("Description (optional)")
                            TextField("What this bot does", text: $descriptor, axis: .vertical)
                                .fieldInput()
                                .lineLimit(2...4)
                        }
                    }

                    fieldGroup(title: "Model") {
                        VStack(spacing: 14) {
                            Picker("", selection: $selectedModel) {
                                Text("Server default").tag("")
                                if isLoadingModels {
                                    Text("Loading…").tag("__loading__")
                                } else {
                                    ForEach(modelList, id: \.self) { m in
                                        Text(m).tag(m)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .font(.system(size: 15))
                            .foregroundStyle(NexusStyle.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(isLoadingModels)
                        }
                    }

                    fieldGroup(title: "Server") {
                        Picker("", selection: $selectedServerID) {
                            Text("Select a server").tag("")
                            ForEach(relay.servers) { s in
                                Text(s.isOnline ? "● \(s.name)" : "○ \(s.name)").tag(s.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 15))
                        .foregroundStyle(NexusStyle.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    fieldGroup(title: "Personality (SOUL.md, optional)") {
                        TextEditor(text: $soul)
                            .frame(minHeight: 90)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(NexusStyle.text)
                            .scrollContentBackground(.hidden)
                            .tint(NexusStyle.blue)
                    }

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }

                    Text("Each bot is a Hermes profile with its own model, memory and settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(NexusStyle.subtleText)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
            }
            .background(NexusStyle.background)
            .navigationTitle("New bot")
            .navigationBarTitleDisplayMode(.inline)
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
            Task { await loadModels() }
        }
        .onChange(of: selectedServerID) { _ in
            selectedModel = ""
            Task { await loadModels() }
        }
    }

    private func fieldGroup(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NexusStyle.subtleText)
                .padding(.horizontal, 4)
            content()
                .padding(14)
                .background(NexusStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(NexusStyle.muted)
    }

    /// Pull the live model list from the selected server (model.options);
    /// fall back to the static list when offline/unavailable.
    private func loadModels() async {
        guard !selectedServerID.isEmpty else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        // model.options call goes direct to the selected server (not the
        // active one), like roster refresh.
        do {
            let res = try await relay.call(serverID: selectedServerID,
                                           method: "model.options",
                                           params: ["include_unconfigured": false])
            var names: [String] = []
            if let dict = res as? [String: Any] {
                // Shape: {providers: [{provider: "x", models: ["a","b"]}]}
                if let providers = dict["providers"] as? [[String: Any]] {
                    for p in providers {
                        if let models = p["models"] as? [String] {
                            names.append(contentsOf: models)
                        } else if let models = p["models"] as? [[String: Any]] {
                            names.append(contentsOf: models.compactMap { $0["name"] as? String })
                        }
                    }
                }
            }
            modelList = names.isEmpty ? fallbackModels : Array(NSOrderedSet(array: names)).compactMap { $0 as? String }
        } catch {
            modelList = fallbackModels
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