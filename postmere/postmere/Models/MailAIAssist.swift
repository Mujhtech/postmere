import Foundation

// Smaller AI assistance shared by the Mac and iPhone apps. Each call goes to the
// workspace server, which only reads the user's own messages and only when they
// have turned AI on.

nonisolated struct MailQuickReply: Codable, Hashable, Identifiable, Sendable {
    let label: String
    let text: String
    var id: String { label + "\u{1F}" + text }
}

nonisolated struct MailProofreadIssue: Codable, Hashable, Identifiable, Sendable {
    let kind: String
    let excerpt: String
    let suggestion: String
    let explanation: String
    var id: String { kind + "\u{1F}" + excerpt + "\u{1F}" + suggestion }

    var title: String {
        switch kind {
        case "spelling": "Spelling"
        case "grammar": "Grammar"
        case "name": "Name"
        case "date": "Date"
        case "clarity": "Clarity"
        case "tone": "Tone"
        default: "Check"
        }
    }

    var symbol: String {
        switch kind {
        case "spelling", "grammar": "textformat.abc"
        case "name": "person.crop.circle.badge.questionmark"
        case "date": "calendar.badge.exclamationmark"
        case "tone": "face.smiling"
        default: "text.magnifyingglass"
        }
    }
}

nonisolated struct MailLearnedStyle: Decodable, Sendable {
    let learnedStyle: String
    let learnedAt: Date
    let messagesRead: Int
}

nonisolated struct MailSearchTranslation: Decodable, Sendable {
    let query: String
    let explanation: String
}

nonisolated struct MailDocumentSummary: Decodable, Sendable {
    nonisolated struct Point: Decodable, Hashable, Sendable {
        let kind: String
        let text: String
        var symbol: String {
            switch kind {
            case "date": "calendar"
            case "amount": "banknote"
            case "action": "checkmark.circle"
            case "party": "person.2"
            default: "info.circle"
            }
        }
    }
    let summary: String
    let points: [Point]
}

nonisolated struct MailActionItem: Decodable, Hashable, Identifiable, Sendable {
    let title: String
    let dueAt: Date?
    let sourceId: UUID
    var id: String { title + "\u{1F}" + sourceId.uuidString }
}

/// A label the user describes in words; new mail that fits is given that label.
nonisolated struct MailDescribedLabel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    /// The provider label applied to matching mail.
    var labelName: String
    var description: String
    var enabled = true
}

enum MailAIAssist {
    private nonisolated struct MessagesBody: Encodable, Sendable { let messageIds: [UUID] }
    private nonisolated struct Replies: Decodable, Sendable { let replies: [MailQuickReply] }
    private nonisolated struct ProofreadBody: Encodable, Sendable {
        let draftText: String
        let subject: String
        let recipients: [String]
        let messageIds: [UUID]
    }
    private nonisolated struct Issues: Decodable, Sendable { let issues: [MailProofreadIssue] }
    private nonisolated struct SearchBody: Encodable, Sendable { let request: String }
    private nonisolated struct DocumentBody: Encodable, Sendable { let messageId: UUID; let filename: String; let text: String }
    private nonisolated struct Tasks: Decodable, Sendable { let tasks: [MailActionItem] }
    private nonisolated struct ClassifyLabel: Encodable, Sendable { let id: String; let name: String; let description: String }
    private nonisolated struct ClassifyBody: Encodable, Sendable { let labels: [ClassifyLabel]; let messageIds: [UUID] }
    nonisolated struct Classification: Decodable, Sendable { let messageId: UUID; let labelIds: [String] }
    private nonisolated struct Classifications: Decodable, Sendable { let matches: [Classification] }

    /// Replies are worth suggesting to people, not to newsletters or no-reply senders.
    @MainActor static func suggestsReplies(to message: MailMessage) -> Bool {
        let address = message.senderEmail.lowercased()
        let automated = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications@", "mailer-daemon"]
            .contains { address.contains($0) }
        return !automated && !message.isSubscriptionMail && !message.isPurchaseMail
            && message.unsubscribeHeaders?.listUnsubscribe.isEmpty != false
    }

    /// Whether the server can still read a message. It refuses a request that names
    /// any message it can't, so drafts, Outbox items and deleted mail stay out.
    @MainActor static func isReadableOnServer(_ message: MailMessage) -> Bool {
        message.backendMessageID != nil && !message.isDraft && !message.isDeletedOnProvider
            && message.mailbox != .outbox && message.mailAccount.isConnected
    }

    /// The server IDs of a conversation, oldest first: the newest 30, which is all the server reads.
    @MainActor static func serverIDs(_ messages: [MailMessage]) -> [UUID] {
        var seen = Set<UUID>()
        let ids = messages.filter(isReadableOnServer).sorted { $0.sentAt < $1.sentAt }
            .compactMap(\.backendMessageID).filter { seen.insert($0).inserted }
        return Array(ids.suffix(30))
    }

    /// The conversation a draft replies to, as context for Write with AI.
    @MainActor static func writerSourceIDs(store: MailStore, scope: String?) -> [UUID] {
        guard let scope else { return [] }
        let conversation = store.messages.filter {
            $0.conversationID == store.draftConversationID && $0.account == store.draftAccount.rawValue
                && $0.mailAccount.remote?.scope == scope
        }
        return serverIDs(conversation)
    }

    @MainActor static func quickReplies(for conversation: [MailMessage], session: BackendSession) async throws -> [MailQuickReply] {
        let ids = serverIDs(conversation.filter { !$0.isDraft })
        guard !ids.isEmpty else { return [] }
        let result: Replies = try await session.request("POST", "/v1/ai/quick-replies", body: MessagesBody(messageIds: ids))
        return result.replies
    }

    @MainActor static func proofread(draft: String, subject: String, recipients: [String], context: [MailMessage],
                                      session: BackendSession) async throws -> [MailProofreadIssue] {
        let result: Issues = try await session.request("POST", "/v1/ai/proofread", body: ProofreadBody(
            draftText: draft, subject: subject, recipients: recipients, messageIds: serverIDs(context)))
        return result.issues
    }

    @MainActor static func learnStyle(session: BackendSession) async throws -> MailLearnedStyle {
        try await session.request("POST", "/v1/ai/style/learn", body: BackendEmpty())
    }

    @MainActor static func translateSearch(_ request: String, session: BackendSession) async throws -> MailSearchTranslation {
        try await session.request("POST", "/v1/ai/search", body: SearchBody(request: request))
    }

    @MainActor static func summarizeDocument(text: String, filename: String, message: MailMessage,
                                              session: BackendSession) async throws -> MailDocumentSummary {
        guard let id = message.backendMessageID else { throw BackendError.response(400, "This message isn’t on your server yet.") }
        return try await session.request("POST", "/v1/ai/document",
                                         body: DocumentBody(messageId: id, filename: filename, text: String(text.prefix(60_000))))
    }

    @MainActor static func actionItems(for conversation: [MailMessage], session: BackendSession) async throws -> [MailActionItem] {
        let ids = serverIDs(conversation.filter { !$0.isDraft })
        guard !ids.isEmpty else { return [] }
        let result: Tasks = try await session.request("POST", "/v1/ai/tasks", body: MessagesBody(messageIds: ids))
        return result.tasks
    }

    @MainActor static func classify(_ messageIDs: [UUID], labels: [MailDescribedLabel],
                                     session: BackendSession) async throws -> [Classification] {
        let body = ClassifyBody(labels: labels.map { ClassifyLabel(id: $0.id, name: $0.labelName, description: $0.description) },
                                messageIds: Array(messageIDs.prefix(20)))
        let result: Classifications = try await session.request("POST", "/v1/ai/classify", body: body)
        return result.matches
    }

    /// A question for Ask that produces the daily briefing.
    static let briefingQuestion = "Brief me on my mail from today: what needs me first, anything with a deadline or meeting today, then the rest in a sentence or two. Group newsletters and notifications into one short line."

    /// The instruction Write with AI gets for a nudge on a conversation that went quiet.
    static let nudgeNotes = "Write a short, friendly follow-up to my last message, which hasn't had a reply. Briefly restate what I need, without guilt-tripping, in two or three sentences."
}

/// Words in a draft that promise a file. Checked on the device before sending.
nonisolated enum MailAttachmentReminder {
    private static let phrases = [
        "attached", "attaching", "attachment", "enclosed", "i've included", "i have included", "please find",
        "see the file", "see the pdf", "see the doc", "here's the file", "here is the file", "sending you the",
        "adjunto", "ci-joint", "pièce jointe", "anbei", "im anhang", "in allegato", "em anexo",
    ]

    /// True when the text the person wrote (not the quoted history below it) mentions an attachment.
    nonisolated static func mentionsAttachment(_ body: String) -> Bool {
        var own: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") || (trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:"))
                || trimmed.hasPrefix("---------- Forwarded message") { break }
            own.append(line)
        }
        let text = own.joined(separator: " ").lowercased()
        return phrases.contains { phrase in
            guard let range = text.range(of: phrase) else { return false }
            // "unattached", "detached" and the like are not promises of a file.
            if phrase == "attached", range.lowerBound > text.startIndex {
                let before = text[text.index(before: range.lowerBound)]
                if before.isLetter { return false }
            }
            return true
        }
    }
}
