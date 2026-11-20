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

nonisolated struct MailSpamDecision: Codable, Equatable, Sendable {
    enum Verdict: String, Codable {
        case possibleSpam = "possible_spam"
        case noSpamSignals = "no_spam_signals"
        case uncertain
    }
    let messageId: UUID
    let verdict: Verdict
    let reason: String
}

nonisolated struct StoredSpamCheck: Codable, Equatable, Sendable {
    let decision: MailSpamDecision
    var isVisible: Bool
}

extension MailMessage {
    /// Selects a small set for opt-in review. These signals never move or label mail.
    nonisolated var hasSpamCheckSignals: Bool {
        let name = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let claimedAddress = name.split(separator: "@", omittingEmptySubsequences: false)
        if claimedAddress.count == 2, !claimedAddress[0].isEmpty, claimedAddress[1].contains("."),
           !name.contains(where: \.isWhitespace), let actual = incomingSenderDomain,
           claimedAddress[1].lowercased() != actual { return true }
        if attachments.prefix(24).contains(where: {
            MailSpamSignals.executableExtensions.contains(($0.name as NSString).pathExtension.lowercased())
        }) { return true }
        let text = [subject, preview, paragraphs.first ?? ""].map {
            String(decoding: $0.utf8.prefix(640), as: UTF8.self)
        }.joined(separator: "\n").lowercased()
        if MailSpamSignals.prizeClaims.contains(where: text.contains)
            && MailSpamSignals.upfrontPayments.contains(where: text.contains) { return true }
        return text.split(whereSeparator: { ".!?\n".contains($0) }).contains { sentence in
            !MailSpamSignals.warnings.contains(where: sentence.contains)
                && MailSpamSignals.secretRequest.firstMatch(in: String(sentence), range: NSRange(location: 0, length: sentence.utf16.count)) != nil
        }
    }
}

private nonisolated enum MailSpamSignals {
    static let executableExtensions: Set<String> = ["exe", "scr", "hta", "cmd", "bat", "vbs", "js", "lnk", "ps1"]
    static let prizeClaims = ["claim your prize", "collect your winnings", "you have won", "lottery winner"]
    static let upfrontPayments = ["processing fee", "advance fee", "wire transfer", "gift card", "crypto payment"]
    static let warnings = ["never", "do not", "don't", "don’t", "will not", "won't", "won’t", "avoid "]
    static let secretRequest = try! NSRegularExpression(pattern:
        #"\b(?:reply (?:to (?:us|me|this (?:message|email)) )?with|send (?:me|us)|provide)\s+(?:us with\s+)?your\s+(?:password|pin\b|(?:verification|security|one[ -]time) code|seed phrase|recovery phrase)\b"#)
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
    case inbox, starred, sent, drafts, archive, junk, trash
    case needsReply, snoozed, followUps, newSenders, outbox

    var id: String { rawValue }
    var isConversationQueue: Bool { [.needsReply, .snoozed, .followUps, .newSenders].contains(self) }
    var isJunkOrTrash: Bool { self == .junk || self == .trash }

    /// Older sync responses placed unrecognized provider folders in Archive.
    /// Graph's opaque folder IDs must be resolved by the account's sync worker.
    func correctingLegacyJunk(labels: [String], provider: String? = nil) -> Self {
        guard self == .archive else { return self }
        if provider != "microsoft", labels.contains("SPAM") { return .junk }
        if provider != "gmail", labels == ["junkemail"] { return .junk }
        return self
    }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .archive: "Archive"
        case .junk: "Junk"
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
        case .junk: "exclamationmark.shield"
        case .trash: "trash"
        case .needsReply: "arrowshape.turn.up.left"
        case .snoozed: "moon.zzz"
        case .followUps: "bell.badge"
        case .newSenders: "person.crop.circle.badge.questionmark"
        case .outbox: "tray.and.arrow.up"
        }
    }
}

nonisolated struct MailAttachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var detail: String
    var localURL: URL?
    var providerAttachmentID: String? = nil
    var providerMessageID: String? = nil
    var providerAccountEmail: String? = nil
    var mimeType: String? = nil
    var byteCount: Int? = nil
    var inlineCalendarData: Data? = nil

    var isCalendarFile: Bool {
        if name.lowercased().hasSuffix(".ics") { return true }
        let type = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return type == "text/calendar" || type == "application/ics" || type == "application/icalendar"
    }

    static let maximumCalendarBytes = 512 * 1_024
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

nonisolated struct MailVerifiedSenderMark: Codable, Equatable, Sendable {
    let messageID: UUID
    let account: String
    let domain: String
    let verifier: String
    let expiresAt: Date
    let logoPNG: Data

    func matches(_ message: MailMessage) -> Bool {
        expiresAt > .now && messageID == message.backendMessageID && account == message.account && message.incomingSenderDomain == domain
    }

    var explanation: String {
        "\(verifier) verified that this message came from \(domain) and that the sender controls the displayed logo."
    }
}

struct MailMessage: Codable, nonisolated Equatable, Identifiable {
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
    var replyRequestText: String?
    var replyRequestCandidates: [String]?
    var automaticReplyPending: Bool?

    nonisolated var isFromAccountOwner: Bool {
        isOutgoing || mailbox == .sent || (
            providerAccountEmail?.isEmpty == false &&
            providerAccountEmail?.caseInsensitiveCompare(senderEmail) == .orderedSame
        )
    }

    nonisolated var allowsWorkflowActions: Bool { !isDraft && mailbox != .junk && mailbox != .outbox }

    nonisolated var needsReply: Bool {
        guard mailbox != .junk else { return false }
        return workflow.needsReply || (automaticReplyPending == true && mailbox == .inbox
            && workflow.screeningState == .accepted && !isDeletedOnProvider)
    }
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
    var verifiedSenderMark: MailVerifiedSenderMark?
    var providerDeletedAt: Date?
    // Optional so mailbox snapshots created before unsubscribe support still decode.
    var unsubscribeHeaders: MailUnsubscribeHeaders?
    var hasMailingListID: Bool?
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

    // Newsletter preheaders often end in invisible padding that wraps into an empty line.
    private nonisolated static let previewPadding = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\u{00AD}\u{034F}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}")
    )

    nonisolated var displayPreview: String {
        preview.trimmingCharacters(in: Self.previewPadding)
    }

    static func displaySubject(_ subject: String) -> String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(No subject)" : subject
    }

    nonisolated var isDraft: Bool { mailbox == .drafts || (mailbox == .trash && trashedFrom == .drafts) }

    nonisolated var incomingSenderDomain: String? {
        guard !isOutgoing, !isDraft, mailbox != .outbox, providerDeletedAt == nil else { return nil }
        let parts = senderEmail.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[1].lowercased()
    }

    nonisolated var currentSenderMark: MailVerifiedSenderMark? {
        guard let mark = verifiedSenderMark, mark.matches(self) else { return nil }
        return mark
    }

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
