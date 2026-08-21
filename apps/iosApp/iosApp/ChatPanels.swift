import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// TG-style attach panel: Photo / File / Camera. Attachments are staged as
/// text annotations next to the compose field, then sent as part of the
/// prompt (`[📎 file.pdf] ...`). The low-trust relay has no file-attach RPC,
/// so the attachment is a named reference the bot can read locally.
struct AttachPanel: View {
    var onAttach: (AttachKind) -> Void
    @State private var showDocPicker = false

    enum AttachKind: Equatable {
        case photo(String)      // display name
        case file(String)       // file name
        case camera             // capture stub
    }

    var body: some View {
        HStack(spacing: 16) {
            PhotosPicker(selection: $photoItem) {
                VStack(spacing: 6) {
                    IconTile(systemName: "photo", tint: NexusStyle.blue)
                    Text("Photo").font(.system(size: 11)).foregroundStyle(NexusStyle.muted)
                }
            }
            Button {
                showDocPicker = true
            } label: {
                VStack(spacing: 6) {
                    IconTile(systemName: "doc", tint: NexusStyle.blue)
                    Text("File").font(.system(size: 11)).foregroundStyle(NexusStyle.muted)
                }
            }
            .buttonStyle(.plain)
            Button {
                onAttach(.camera)
            } label: {
                VStack(spacing: 6) {
                    IconTile(systemName: "camera", tint: NexusStyle.blue)
                    Text("Camera").font(.system(size: 11)).foregroundStyle(NexusStyle.muted)
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(NexusStyle.background2)
        .overlay(alignment: .top) { Divider().overlay(NexusStyle.border) }
        .fileImporter(isPresented: $showDocPicker, allowedContentTypes: [.data, .pdf, .text, .image]) { result in
            if case .success(let url) = result {
                onAttach(.file(url.lastPathComponent))
            }
        }
    }

    @State private var photoItem: PhotosPickerItem?
}

/// Staged attachment chip — sits above the input bar while composing.
struct AttachChip: View {
    let label: String
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 11))
                .foregroundStyle(NexusStyle.blue)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NexusStyle.text)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(NexusStyle.subtleText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(NexusStyle.row, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
    }
}

private struct IconTile: View {
    let systemName: String
    let tint: Color
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(NexusStyle.row)
                .frame(width: 54, height: 54)
            Image(systemName: systemName)
                .font(.system(size: 24))
                .foregroundStyle(tint)
        }
    }
}

/// TG-style command suggestion card — appears above the input bar while the
/// user types a `/`-prefixed command. Selecting one fills the input.
/// (Commands are app-side affordances sent as prompt text; server-side slash
/// semantics are a follow-up.)
struct CommandSuggestCard: View {
    @Binding var input: String

    struct Command: Identifiable {
        let id: String
        let slug: String
        let desc: String
    }

    static let commands: [Command] = [
        .init(id: "status", slug: "/status", desc: "Show server & relay status"),
        .init(id: "help", slug: "/help", desc: "List available commands"),
        .init(id: "agents", slug: "/agents", desc: "List agents & sessions"),
        .init(id: "model", slug: "/model", desc: "Switch or show model"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.commands) { cmd in
                Button {
                    input = cmd.slug + " "
                } label: {
                    HStack(spacing: 12) {
                        Text(cmd.slug)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(NexusStyle.blue)
                            .frame(minWidth: 74, alignment: .leading)
                        Text(cmd.desc)
                            .font(.system(size: 13.5))
                            .foregroundStyle(NexusStyle.muted)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if cmd.id != Self.commands.last?.id {
                    Divider().overlay(NexusStyle.border)
                }
            }
        }
        .background(NexusStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NexusStyle.border, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 14)
    }
}