import SwiftUI

/// Chat with a bot (a Hermes profile). T5 fills timeline + TG input bar +
/// emoji/attach/command panels; this is the T3 build-green skeleton.
struct ChatView: View {
    let bot: Bot
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NexusStyle.blue)
                }
                ZStack {
                    Circle().fill(NexusStyle.blue).frame(width: 34, height: 34)
                    Text(String(bot.displayTitle.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NexusStyle.text)
                    Text(bot.status == .offline ? "Offline" : "Online")
                        .font(.system(size: 11))
                        .foregroundStyle(bot.status == .offline ? NexusStyle.subtleText : NexusStyle.green)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider().overlay(NexusStyle.border)
            Spacer()
            Text("Chat with \(bot.displayTitle)")
                .foregroundStyle(NexusStyle.muted)
            Spacer()
            Divider().overlay(NexusStyle.border)
            HStack(spacing: 8) {
                TextField("Message \(bot.displayTitle)…", text: .constant(""))
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
                    .disabled(true)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(NexusStyle.subtleText)
            }
            .padding(12)
            .background(NexusStyle.card)
        }
        .background(NexusStyle.background)
    }
}