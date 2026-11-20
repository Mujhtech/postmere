import Foundation

enum SenderScreeningState: String, Codable, CaseIterable, Identifiable {
    case accepted, pending, blocked
    var id: Self { self }
}

nonisolated struct MailWorkflowState: Codable, Equatable {
    var needsReply = false
    var replyDecisionAt: Date?
    var snoozedUntil: Date?
    var followUpAt: Date?
    var followUpOnlyIfNoReply = true
    var followUpReferenceDate: Date?
    var privateNote = ""
    var screeningState: SenderScreeningState = .accepted
    var scheduledSendAt: Date?
}

struct MailSnippet: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case snippet, template }
    var id: UUID
    var title: String
    var body: String
    var kind: Kind
    var bodyRTF: Data?
    /// nil leaves a draft field untouched; an included empty field can clear it.
    var to: String?
    var cc: String?
    var bcc: String?
    var subject: String?
    var attachments: [MailAttachment]

    var isTemplate: Bool {
        kind == .template || to != nil || cc != nil || bcc != nil || subject != nil || !attachments.isEmpty
    }

    init(id: UUID = UUID(), title: String, body: String, kind: Kind = .snippet,
         bodyRTF: Data? = nil, to: String? = nil, cc: String? = nil, bcc: String? = nil,
         subject: String? = nil, attachments: [MailAttachment] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.bodyRTF = bodyRTF
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case id, title, body, kind, bodyRTF, to, cc, bcc, subject, attachments }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .snippet
        bodyRTF = try values.decodeIfPresent(Data.self, forKey: .bodyRTF)
        to = try values.decodeIfPresent(String.self, forKey: .to)
        cc = try values.decodeIfPresent(String.self, forKey: .cc)
        bcc = try values.decodeIfPresent(String.self, forKey: .bcc)
        subject = try values.decodeIfPresent(String.self, forKey: .subject)
        attachments = try values.decodeIfPresent([MailAttachment].self, forKey: .attachments) ?? []
    }
}

nonisolated struct SavedInboxCriteria: Codable, Equatable {
    var query = ""
    var account: String?
    var unreadOnly = false
    var attachmentsOnly = false
    var starredOnly = false
    var sender = ""
    var domain = ""
    var mailbox: Mailbox? = .inbox
    var searchField: MailSearchField = .all

    private enum CodingKeys: String, CodingKey {
        case query, account, unreadOnly, attachmentsOnly, starredOnly, sender, domain, mailbox, searchField
    }

    init(query: String = "", account: String? = nil, unreadOnly: Bool = false,
         attachmentsOnly: Bool = false, starredOnly: Bool = false, sender: String = "",
         domain: String = "", mailbox: Mailbox? = .inbox, searchField: MailSearchField = .all) {
        self.query = query
        self.account = account
        self.unreadOnly = unreadOnly
        self.attachmentsOnly = attachmentsOnly
        self.starredOnly = starredOnly
        self.sender = sender
        self.domain = domain
        self.mailbox = mailbox
        self.searchField = searchField
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        query = try values.decodeIfPresent(String.self, forKey: .query) ?? ""
        account = try values.decodeIfPresent(String.self, forKey: .account)
        unreadOnly = try values.decodeIfPresent(Bool.self, forKey: .unreadOnly) ?? false
        attachmentsOnly = try values.decodeIfPresent(Bool.self, forKey: .attachmentsOnly) ?? false
        starredOnly = try values.decodeIfPresent(Bool.self, forKey: .starredOnly) ?? false
        sender = try values.decodeIfPresent(String.self, forKey: .sender) ?? ""
        domain = try values.decodeIfPresent(String.self, forKey: .domain) ?? ""
        // The previous synthesized encoder omitted nil (All Mailboxes).
        mailbox = try values.decodeIfPresent(Mailbox.self, forKey: .mailbox)
        searchField = try values.decodeIfPresent(MailSearchField.self, forKey: .searchField) ?? .all
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(query, forKey: .query)
        try values.encodeIfPresent(account, forKey: .account)
        try values.encode(unreadOnly, forKey: .unreadOnly)
        try values.encode(attachmentsOnly, forKey: .attachmentsOnly)
        try values.encode(starredOnly, forKey: .starredOnly)
        try values.encode(sender, forKey: .sender)
        try values.encode(domain, forKey: .domain)
        // Keep the all-mailboxes scope explicit in newly written snapshots.
        try values.encode(mailbox, forKey: .mailbox)
        try values.encode(searchField, forKey: .searchField)
    }
}

struct SavedInboxView: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var criteria: SavedInboxCriteria
}

enum SenderRoute: String, Codable, CaseIterable, Identifiable {
    case inbox, archive, needsReply, blocked
    var id: Self { self }
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .archive: "Archive"
        case .needsReply: "Needs Reply"
        case .blocked: "Blocked"
        }
    }
}

struct SenderRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var email: String
    var account: String?
    var route: SenderRoute
    var providerAccountEmail: String? = nil
}

struct OutgoingMailItem: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case pending, delivering, failed }
    var id: UUID { messageID }
    var messageID: UUID
    var queuedAt: Date
    var undoUntil: Date
    var scheduledAt: Date
    var status: Status = .pending
    var lastError: String?
    var serverJobID: UUID?
    var serverState: String?
    var submissionStarted: Bool?
    var cancellationRequested: Bool?
}

struct ActiveMailDraft: Codable, Equatable {
    var editingMessageID: UUID?
    var conversationID: UUID
    var account: MailAccount
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
    var bodyRTF: Data?
    var attachments: [MailAttachment]
    var composeTitle: String
    var sendAt: Date?
    var followUpAt: Date?
    var followUpOnlyIfNoReply: Bool
    var inReplyTo: String?
    var references: [String]
    var providerThreadID: String?
    var providerAccountEmail: String?
    var trackOpens: Bool?
    var trackLinks: Bool?
}

struct MailNotificationSchedule: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case snooze, followUp }
    var id: String { "\(kind.rawValue)-\(conversationID.uuidString)" }
    var conversationID: UUID
    var messageID: UUID
    var title: String
    var date: Date
    var kind: Kind
}

nonisolated struct ProviderMessageOverride: Equatable, Sendable {
    var isUnread: Bool?
    var isStarred: Bool?
    var mailbox: Mailbox?
    var isEmpty: Bool { isUnread == nil && isStarred == nil && mailbox == nil }

    mutating func apply(to message: inout MailMessage) {
        if let value = isUnread {
            if message.isUnread == value { isUnread = nil } else { message.isUnread = value }
        }
        if let value = isStarred {
            if message.isStarred == value { isStarred = nil } else { message.isStarred = value }
        }
        if let value = mailbox {
            if message.mailbox == value { mailbox = nil } else { message.mailbox = value }
        }
    }
}
