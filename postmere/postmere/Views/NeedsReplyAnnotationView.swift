import SwiftUI

struct NeedsReplyAnnotation {
    enum Origin {
        case marked
        case detected(request: String, sender: String)
    }

    let messageID: UUID
    let origin: Origin

    init?(selected: MailMessage, conversation: [MailMessage]) {
        guard selected.allowsWorkflowActions, !selected.mailbox.isJunkOrTrash else { return nil }
        // Reader conversations are in chronological order. An older message may hold
        // the pending request even when the reader opened a newer message in the thread.
        if let marked = conversation.last(where: { $0.needsReply && $0.workflow.needsReply }) {
            messageID = marked.id
            origin = .marked
        } else if let source = conversation.last(where: { $0.needsReply && $0.automaticReplyPending == true }),
                  let request = source.replyRequestText, !request.isEmpty {
            messageID = source.id
            origin = .detected(request: request, sender: source.sender.isEmpty ? source.senderEmail : source.sender)
        } else {
            return nil
        }
    }
}

struct NeedsReplyAnnotationView: View {
    let annotation: NeedsReplyAnnotation
    let inThread: Bool
    let showSource: () -> Void
    let markDone: () -> Void

    @Environment(\.postmereAccent) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                Text("Needs Reply")
                    .font(.headline)
                    .foregroundStyle(palette.accentInk)
                    .accessibilityAddTraits(.isHeader)
                Button(action: markDone) {
                    Label("Mark Done", systemImage: "checkmark")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove this conversation from Needs Reply")
            }
            switch annotation.origin {
            case .marked:
                Text("Marked for reply in Postmere")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .detected(let request, let sender):
                Text(verbatim: "“\(request)”")
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                if inThread {
                    Button(action: showSource) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Detected in mail from \(sender)")
                            Image(systemName: "arrow.down").imageScale(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(palette.accentInk)
                    .help("Show the message containing this request")
                    .accessibilityHint("Opens the original message in this conversation.")
                } else {
                    Text("Detected in mail from \(sender)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 11)
        .overlay(alignment: .leading) {
            Capsule().fill(palette.accentInk.opacity(0.72)).frame(width: 2)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
