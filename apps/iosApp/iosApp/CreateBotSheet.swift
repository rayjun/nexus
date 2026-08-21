import SwiftUI

/// Placeholder for T3 build-green; real implementation in T4.
struct CreateBotSheet: View {
    @ObservedObject var store: ChatStore
    var onCreated: ((Bot) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(NexusStyle.subtleText)
                Text("CreateBotSheet — full form in next step")
                    .font(.system(size: 14))
                    .foregroundStyle(NexusStyle.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NexusStyle.background)
            .navigationTitle("New bot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}