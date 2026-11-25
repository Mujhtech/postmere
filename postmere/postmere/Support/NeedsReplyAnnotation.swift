import Foundation

/// Why a conversation is in Needs Reply: marked by you, or a request detected in the mail.
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
