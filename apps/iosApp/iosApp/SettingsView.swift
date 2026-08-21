import SwiftUI

/// Placeholder for T3 build-green; full settings UI in T4.
struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @EnvironmentObject private var relay: RelayClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Settings — full UI in next step")
                .foregroundStyle(NexusStyle.muted)
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

/// Placeholder for T3 build-green; rename/delete UI in T4.
struct BotManageSheet: View {
    @ObservedObject var store: ChatStore
    let bot: Bot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Manage \(bot.displayTitle) — full UI in next step")
                .foregroundStyle(NexusStyle.muted)
                .navigationTitle(bot.displayTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}