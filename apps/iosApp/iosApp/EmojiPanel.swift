import SwiftUI

/// TG-style emoji picker panel: Emoji / Stickers / Files tabs + grid.
/// Shown between the message area and the input bar (input bar stays
/// visible); tapping an emoji inserts it into the input field.
enum ChatPanel: Equatable {
    case none
    case emoji
    case attach
}

struct EmojiPanel: View {
    @Binding var input: String
    @State private var tab: Tab = .emoji

    enum Tab: String, CaseIterable {
        case emoji = "Emoji"
        case stickers = "Stickers"
        case files = "Files"
    }

    private let emojiGrid: [[String]] = [
        ["😀","😂","😊","🤔","👍","🔥","🎉","❤️"],
        ["✅","❌","⚠️","🔧","📎","📁","💾","🚀"],
        ["🐛","🧪","📄","🗂","📈","💡","🧠","🤝"],
        ["⚡","🔒","🛡","🌐","📦","🧹","🔄","⏱"],
    ]

    private let stickers: [[String]] = [
        ["🐶","🐱","🐼","🦊","🐸","🦄","🐙","🦖"],
        ["🍕","☕","🍩","🍎","🌶","🥑","🍜","🍺"],
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button {
                        tab = t
                    } label: {
                        Text(t.rawValue)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tab == t ? .white : NexusStyle.muted)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(tab == t ? NexusStyle.blue : NexusStyle.row,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tab == .emoji ? emojiGrid : stickers, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(row, id: \.self) { emoji in
                                Button {
                                    input += emoji
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: 26))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(height: 148)
        }
        .background(NexusStyle.background2)
        .overlay(alignment: .top) { Divider().overlay(NexusStyle.border) }
    }
}