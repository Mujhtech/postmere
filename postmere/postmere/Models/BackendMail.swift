import Foundation
import CryptoKit

nonisolated struct BackendAccount: Codable, Identifiable, Sendable {
    let id: UUID
    let provider: String
    let email: String
    let displayName: String?
    let status: String
    let lastSyncedAt: Date?
    var capabilities: [String]? = nil
}

nonisolated struct BackendAddress: Codable, Sendable {
    var name: String?
    var email: String
}

nonisolated struct BackendAttachment: Codable, Identifiable, Sendable {
    let id: UUID
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let providerAttachmentId: String?
}

nonisolated struct BackendMailPage: Decodable, Sendable {
    let messages: [BackendMailMessage]
    let nextCursor: String?
    let hasMore: Bool
    var deletedMessageIds: [UUID]? = nil
}

nonisolated struct BackendMailMessage: Decodable, Sendable {
    let id: UUID
    let accountId: UUID
    let providerMessageId: String
    let providerThreadId: String?
    let subject: String
    let from: BackendAddress
    let to: [BackendAddress]
    let cc: [BackendAddress]
    let bcc: [BackendAddress]
    let textBody: String
    let htmlBody: String?
    let preview: String
    let sentAt: Date
    let isRead: Bool
    let isStarred: Bool
    let mailbox: String
    let providerLabels: [String]
    let attachments: [BackendAttachment]
    let listUnsubscribe: [String]
    let listUnsubscribePost: [String]
    var rfcMessageId: String? = nil
    var inReplyTo: String? = nil
    var references: [String]? = nil
}

extension BackendMailMessage {
    func localMessage(identity: RemoteAccountIdentity) -> MailMessage {
        var message = MailMessage(id: Self.localID(identity.localID + ":" + id.uuidString), sender: from.name?.isEmpty == false ? from.name! : from.email,
                    senderEmail: from.email, initials: String((from.name ?? from.email).prefix(2)).uppercased(),
                    subject: subject, preview: preview, paragraphs: [textBody],
                    dateLabel: sentAt.formatted(date: .abbreviated, time: .omitted),
                    timeLabel: sentAt.formatted(date: .omitted, time: .shortened),
                    isUnread: !isRead, isStarred: isStarred, mailbox: Mailbox(rawValue: mailbox) ?? .archive,
                    account: identity.localID, tint: "8BA794", isOutgoing: mailbox == "sent" || from.email.caseInsensitiveCompare(identity.email) == .orderedSame,
                    toRecipients: to.map(\.email), ccRecipients: cc.map(\.email), bccRecipients: bcc.map(\.email),
                    attachments: attachments.map {
                        MailAttachment(id: $0.id, name: $0.filename,
                                       detail: ByteCountFormatter.string(fromByteCount: Int64($0.sizeBytes), countStyle: .file),
                                       providerAttachmentID: $0.id.uuidString, providerMessageID: id.uuidString,
                                       providerAccountEmail: identity.email, mimeType: $0.mimeType, byteCount: $0.sizeBytes)
                    }, conversationID: Self.localID(identity.localID + ":thread:" + (providerThreadId ?? providerMessageId)),
                    sentAt: sentAt, providerMessageID: providerMessageId, providerAccountEmail: identity.email,
                    providerThreadID: providerThreadId, bodyHTML: htmlBody, providerLabelIDs: providerLabels,
                    unsubscribeHeaders: listUnsubscribe.isEmpty ? nil : MailUnsubscribeHeaders(
                        listUnsubscribe: listUnsubscribe, listUnsubscribePost: listUnsubscribePost,
                        authenticationResults: [], dkimSignatures: [], source: identity.provider))
        message.backendMessageID = id
        message.rfcMessageID = rfcMessageId
        message.inReplyTo = inReplyTo
        message.references = references ?? []
        return message
    }

    private static func localID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
