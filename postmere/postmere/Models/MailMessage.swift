import Foundation
import Observation

struct MailAccount: RawRepresentable, Codable, CaseIterable, Identifiable, Hashable {
    let rawValue: String
    // Retained only to decode older caches and to build explicit previews.
    static let unassigned = MailAccount(known: "unassigned")
    static let work = MailAccount(known: "Work")
    static let personal = MailAccount(known: "Personal")
    static let gmail = MailAccount(known: "Gmail")
    private init(known: String) { rawValue = known }
    init?(rawValue: String) {
        guard ["unassigned", "Work", "Personal", "Gmail"].contains(rawValue) || rawValue.hasPrefix("remote:") else { return nil }
        self.rawValue = rawValue
    }
    static var allCases: [MailAccount] { RemoteAccountRegistry.accounts.map { MailAccount(known: $0.localID) } }
    static var sendingAccounts: [MailAccount] { allCases.filter(\.isConnected) }
    var id: String { rawValue }
    var isRemote: Bool { rawValue.hasPrefix("remote:") }
    var isLive: Bool { isRemote }
    var isConnected: Bool { remote?.status == "connected" }
    var remote: RemoteAccountIdentity? { RemoteAccountRegistry.accounts.first { $0.localID == rawValue } }
    var name: String { self == .unassigned ? "Choose an account" : isRemote ? remote?.email ?? "Disconnected account" : rawValue }
    static func scopeLabel(for id: String?, providerEmail: String? = nil) -> String {
        guard let id else { return "All accounts" }
        let account = MailAccount(rawValue: id)
        if let email = account?.remote?.email ?? providerEmail, !email.isEmpty { return email }
        guard let account, account != .unassigned else { return "No account" }
        return account.name
    }
    var displayName: String {
        if isRemote { return remote?.displayName ?? "Me" }
        return self == .work || self == .personal ? "Alex Johnson" : "Me"
    }
    var email: String {
        if self == .work { return "alex@fieldnotes.studio" }
        if self == .personal { return "alex@postmere.app" }
        return remote?.email ?? ""
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let account = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown mail account"))
        }
        self = account
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct RemoteAccountIdentity: Codable, Equatable {
    let localID: String
    let accountID: UUID
    let scope: String
    let email: String
    let displayName: String
    let provider: String
    var status: String = "connected"
}

/// Only active-session identities are exposed. Cached messages retain their full
/// origin/workspace/user/account key across logout and cannot cross identities.
@MainActor
@Observable
final class RemoteAccountRegistry {
    static let shared = RemoteAccountRegistry()
    var values: [RemoteAccountIdentity] = []
    static var accounts: [RemoteAccountIdentity] {
        get { shared.values }
        set { shared.values = newValue }
    }
}

enum MailSearchScope: String, Codable, CaseIterable, Identifiable {
    case currentMailbox, allMailboxes

    var id: Self { self }
    var title: String { self == .currentMailbox ? "Current mailbox" : "All mailboxes" }
}

enum MailSearchField: String, Codable, CaseIterable, Identifiable {
    case all, sender, subject

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All text"
        case .sender: "Sender"
        case .subject: "Subject"
        }
    }
}

nonisolated enum Mailbox: String, Codable, CaseIterable, Identifiable {
    case inbox, starred, sent, drafts, archive, trash
    case needsReply, snoozed, followUps, newSenders, outbox

    var id: String { rawValue }
    var isConversationQueue: Bool { [.needsReply, .snoozed, .followUps, .newSenders].contains(self) }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .archive: "Archive"
        case .trash: "Trash"
        case .needsReply: "Needs Reply"
        case .snoozed: "Snoozed"
        case .followUps: "Follow-ups"
        case .newSenders: "New Senders"
        case .outbox: "Outbox"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .starred: "star"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .trash: "trash"
        case .needsReply: "arrowshape.turn.up.left"
        case .snoozed: "moon.zzz"
        case .followUps: "bell.badge"
        case .newSenders: "person.crop.circle.badge.questionmark"
        case .outbox: "tray.and.arrow.up"
        }
    }
}

struct MailAttachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var detail: String
    var localURL: URL?
    var providerAttachmentID: String? = nil
    var providerMessageID: String? = nil
    var providerAccountEmail: String? = nil
    var mimeType: String? = nil
    var byteCount: Int? = nil
}

/// Original list headers imported from the provider. Keeping duplicates lets
/// unsubscribe parsing reject ambiguous commands instead of silently choosing one.
nonisolated struct MailUnsubscribeHeaders: Codable, Equatable, Sendable {
    var listUnsubscribe: [String]
    var listUnsubscribePost: [String]
    var authenticationResults: [String]
    var dkimSignatures: [String]
    var source: String
}

/// A practical address-list parser for the local composer, without looking up contacts or domains.
struct MailAddressList {
    var addresses: [String] = []
    var invalid: [String] = []

    init(_ input: String) {
        var tokens: [String] = []
        var token = ""
        var insideQuotes = false
        var insideBrackets = false
        for character in input {
            if character == "\"" { insideQuotes.toggle() }
            if character == "<" { insideBrackets = true }
            if character == ">" { insideBrackets = false }
            if [",", ";", "\n"].contains(character) && !insideQuotes && !insideBrackets {
                tokens.append(token)
                token = ""
            } else {
                token.append(character)
            }
        }
        tokens.append(token)

        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var address = trimmed
            if let opening = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">") {
                address = String(trimmed[trimmed.index(after: opening)..<trimmed.index(before: trimmed.endIndex)])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let pattern = #"^[A-Z0-9!#$%&'*+/=?^_`{|}~.-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+$"#
            let local = address.split(separator: "@").first.map(String.init) ?? ""
            let isValid = address.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                && !local.hasPrefix(".") && !local.hasSuffix(".") && !local.contains("..")
            if isValid {
                if !addresses.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
                    addresses.append(address)
                }
            } else {
                invalid.append(trimmed)
            }
        }
    }
}

nonisolated struct MailDeliveryHeaders: Codable, Equatable, Sendable {
    var returnPath: String?
    var receivedWith: String?
}

nonisolated struct MailEnvelopeDetails: Codable, Equatable, Sendable {
    var recipientNames: [String: String]
    var signingDomains: [String]
    var deliveryHeaders: MailDeliveryHeaders?

    /// DKIM-Signature names a signer. Only the receiving service can verify it.
    static func signingDomains(from signatures: [String]) -> [String] {
        var domains: [String] = []
        for signature in signatures {
            let candidates = signature.split(separator: ";").compactMap { tag -> String? in
                let parts = tag.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "d" else { return nil }
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard candidates.count == 1, let domain = candidates.first, domain.utf8.count <= 253,
                  domain.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"#,
                               options: .regularExpression) != nil, !domains.contains(domain) else { continue }
            domains.append(domain)
        }
        return domains
    }
}

struct MailMessage: Codable, Identifiable {
    var id: UUID
    var conversationID: UUID
    var sentAt: Date
    var sender: String
    var senderEmail: String
    var initials: String
    var subject: String
    var preview: String
    var paragraphs: [String]
    var bodyRTF: Data?
    var dateLabel: String
    var timeLabel: String
    var isUnread: Bool
    var isStarred: Bool
    var mailbox: Mailbox
    var account: String
    var tint: String
    var isOutgoing: Bool
    var trashedFrom: Mailbox?
    var toRecipients: [String]
    var ccRecipients: [String]
    var bccRecipients: [String]
    var attachments: [MailAttachment]
    var workflow: MailWorkflowState
    var providerMessageID: String?
    var providerAccountEmail: String?
    var providerThreadID: String?
    var rfcMessageID: String?
    var inReplyTo: String?
    var references: [String]
    var bodyHTML: String?
    var providerLabelIDs: [String]
    var providerCategories: [String]?
    var envelopeDetails: MailEnvelopeDetails?
    var providerDeletedAt: Date?
    // Optional so mailbox snapshots created before unsubscribe support still decode.
    var unsubscribeHeaders: MailUnsubscribeHeaders?
    var backendMessageID: UUID?
    var backendOutboxID: UUID?
    var trackOpens: Bool?
    var trackLinks: Bool?

    /// Connected accounts include the workspace and provider account ID in their key.
    /// Only legacy account keys need an email address to distinguish mailboxes.
    nonisolated var legacyAccountAddress: String? {
        account.hasPrefix("remote:") ? nil : providerAccountEmail?.lowercased()
    }

    nonisolated var isDeletedOnProvider: Bool {
        get { providerDeletedAt != nil }
        set { providerDeletedAt = newValue ? providerDeletedAt ?? .now : nil }
    }

    var mailAccount: MailAccount { MailAccount(rawValue: account) ?? .unassigned }
    var accountLabel: String { MailAccount.scopeLabel(for: account, providerEmail: providerAccountEmail) }
    var displaySubject: String { Self.displaySubject(subject) }

    static func displaySubject(_ subject: String) -> String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(No subject)" : subject
    }

    nonisolated var isDraft: Bool { mailbox == .drafts || (mailbox == .trash && trashedFrom == .drafts) }

    nonisolated var receivedHTML: String? {
        guard !isDraft, mailbox != .outbox, let bodyHTML,
              bodyHTML.contains(where: { !$0.isWhitespace }) else { return nil }
        return bodyHTML
    }

    /// Compatibility for callers that only need the first attachment.
    var attachment: MailAttachment? {
        get { attachments.first }
        set { attachments = newValue.map { [$0] } ?? [] }
    }

    init(
        id: UUID = UUID(),
        sender: String,
        senderEmail: String,
        initials: String,
        subject: String,
        preview: String,
        paragraphs: [String],
        dateLabel: String = "Today",
        timeLabel: String,
        isUnread: Bool = false,
        isStarred: Bool = false,
        mailbox: Mailbox = .inbox,
        account: String = "Work",
        tint: String = "C4B49D",
        attachment: MailAttachment? = nil,
        isOutgoing: Bool? = nil,
        trashedFrom: Mailbox? = nil,
        toRecipients: [String]? = nil,
        ccRecipients: [String] = [],
        bccRecipients: [String] = [],
        attachments: [MailAttachment]? = nil,
        conversationID: UUID? = nil,
        sentAt: Date = .now,
        bodyRTF: Data? = nil,
        workflow: MailWorkflowState = .init(),
        providerMessageID: String? = nil,
        providerAccountEmail: String? = nil,
        providerThreadID: String? = nil,
        rfcMessageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        bodyHTML: String? = nil,
        providerLabelIDs: [String] = [],
        isDeletedOnProvider: Bool = false,
        unsubscribeHeaders: MailUnsubscribeHeaders? = nil
    ) {
        self.id = id
        self.conversationID = conversationID ?? id
        self.sentAt = sentAt
        self.sender = sender
        let outgoing = isOutgoing ?? (mailbox == .sent || mailbox == .drafts || trashedFrom == .sent || trashedFrom == .drafts)
        let identity = MailAccount(rawValue: account) ?? .unassigned
        // Earlier sample messages stored the recipient in senderEmail for outgoing mail.
        self.senderEmail = outgoing && toRecipients == nil ? identity.email : senderEmail
        self.initials = initials
        self.subject = subject
        self.preview = preview
        self.paragraphs = paragraphs
        self.bodyRTF = bodyRTF
        self.dateLabel = dateLabel
        self.timeLabel = timeLabel
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.mailbox = mailbox
        self.account = account
        self.tint = tint
        self.isOutgoing = outgoing
        self.trashedFrom = trashedFrom
        self.toRecipients = toRecipients ?? (outgoing ? [senderEmail] : [identity.email])
        self.ccRecipients = ccRecipients
        self.bccRecipients = bccRecipients
        self.attachments = attachments ?? attachment.map { [$0] } ?? []
        self.workflow = workflow
        self.providerMessageID = providerMessageID
        self.providerAccountEmail = providerAccountEmail
        self.providerThreadID = providerThreadID
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.bodyHTML = bodyHTML
        self.providerLabelIDs = providerLabelIDs
        self.providerDeletedAt = isDeletedOnProvider ? .now : nil
        self.unsubscribeHeaders = unsubscribeHeaders
    }
}
