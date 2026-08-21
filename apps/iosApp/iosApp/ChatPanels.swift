import SwiftUI
import PhotosUI

/// TG-style attach panel: Photo / File / Camera. v2 ships pickers only —
/// the attachment is sent as a text note accompanying the prompt (server
/// has no file-attach RPC on the low-trust allowlist).
struct AttachPanel: View {
    @State private var photoItem: PhotosPickerItem?
    @State private var fileName = ""
    @State private var showDocPicker = false

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
                // Camera capture — v2 placeholder (permission flow in follow-up)
                fileName = "📷 camera attach — coming soon"
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
        .fileImporter(isPresented: $showDocPicker, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                fileName = url.lastPathComponent
            }
        }
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