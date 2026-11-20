import Foundation
import CryptoKit

nonisolated struct BackendAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let provider: String
    let email: String
    let displayName: String?
    let status: String
    let lastSyncedAt: Date?
    var capabilities: [String]? = nil
    var syncStatus: BackendMailSyncStatus? = nil
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
    var inlineDataBase64: String? = nil

    func localAttachment(messageID: UUID, email: String) -> MailAttachment {
        var attachment = MailAttachment(id: id, name: filename,
            detail: ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file),
            providerAttachmentID: id.uuidString, providerMessageID: messageID.uuidString,
            providerAccountEmail: email, mimeType: mimeType, byteCount: sizeBytes)
        if attachment.isCalendarFile, let inlineDataBase64,
           inlineDataBase64.utf8.count <= (MailAttachment.maximumCalendarBytes + 2) / 3 * 4 {
            var encoded = inlineDataBase64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
            if let data = Data(base64Encoded: encoded), data.count <= MailAttachment.maximumCalendarBytes {
                attachment.inlineCalendarData = data
            }
        }
        if attachment.isCalendarFile && sizeBytes == 0 { attachment.detail = "Calendar invitation" }
        return attachment
    }
}

nonisolated struct BackendMailPage: Decodable, Sendable {
    let messages: [BackendMailMessage]
    let nextCursor: String?
    let hasMore: Bool
    var deletedMessageIds: [UUID]? = nil
    var syncStatus: BackendMailSyncStatus? = nil

    @concurrent func localMessages(for identity: RemoteAccountIdentity) async throws -> [MailMessage] {
        var converted: [MailMessage] = []
        converted.reserveCapacity(messages.count)
        for row in messages where row.accountId == identity.accountID {
            try Task.checkCancellation()
            var message = await row.makeLocalMessage(identity: identity)
            message.verifiedSenderMark = await row.verifiedSenderMark?.render(for: message, identity: identity)
            message.restoreReceivedText(provider: identity.provider)
            converted.append(message)
        }
        return converted
    }
}

nonisolated struct BackendMailSyncStatus: Codable, Equatable, Sendable {
    let phase: String
    let retryAt: Date?
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
    var hasMailingListId: Bool? = nil
    var rfcMessageId: String? = nil
    var inReplyTo: String? = nil
    var references: [String]? = nil
    var categories: [String]? = nil
    var dkimSignatures: [String]? = nil
    var deliveryHeaders: MailDeliveryHeaders? = nil
    var verifiedSenderMark: BackendSenderMark? = nil
}

nonisolated struct BackendMessageEnvelope: Decodable, Sendable {
    let id: UUID
    let accountId: UUID
    let to: [BackendAddress]
    let cc: [BackendAddress]
    let bcc: [BackendAddress]
    let dkimSignatures: [String]?
    let deliveryHeaders: MailDeliveryHeaders?

    var details: MailEnvelopeDetails {
        var names: [String: String] = [:]
        for address in to + cc + bcc {
            if let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                names[address.email.lowercased()] = name
            }
        }
        return MailEnvelopeDetails(recipientNames: names,
                                   signingDomains: MailEnvelopeDetails.signingDomains(from: dkimSignatures ?? []),
                                   deliveryHeaders: deliveryHeaders)
    }
}

extension BackendMailMessage {
    var envelopeDetails: MailEnvelopeDetails {
        BackendMessageEnvelope(id: id, accountId: accountId, to: to, cc: cc, bcc: bcc,
                               dkimSignatures: dkimSignatures, deliveryHeaders: deliveryHeaders).details
    }

    func localMessage(identity: RemoteAccountIdentity) -> MailMessage {
        var message = makeLocalMessage(identity: identity)
        message.verifiedSenderMark = verifiedSenderMark?.localMark(for: message, identity: identity)
        message.restoreReceivedText(provider: identity.provider)
        return message
    }

    fileprivate func makeLocalMessage(identity: RemoteAccountIdentity) -> MailMessage {
        let folder = (Mailbox(rawValue: mailbox) ?? .archive)
            .correctingLegacyJunk(labels: providerLabels, provider: identity.provider)
        var message = MailMessage(id: Self.localID(identity.localID + ":" + id.uuidString), sender: from.name?.isEmpty == false ? from.name! : from.email,
                    senderEmail: from.email, initials: String((from.name ?? from.email).prefix(2)).uppercased(),
                    subject: subject, preview: preview, paragraphs: [textBody],
                    dateLabel: sentAt.formatted(date: .abbreviated, time: .omitted),
                    timeLabel: sentAt.formatted(date: .omitted, time: .shortened),
                    isUnread: !isRead, isStarred: isStarred, mailbox: folder,
                    account: identity.localID, tint: "8BA794", isOutgoing: mailbox == "sent" || from.email.caseInsensitiveCompare(identity.email) == .orderedSame,
                    toRecipients: to.map(\.email), ccRecipients: cc.map(\.email), bccRecipients: bcc.map(\.email),
                    attachments: attachments.map { $0.localAttachment(messageID: id, email: identity.email) },
                    conversationID: Self.localID(identity.localID + ":thread:" + (providerThreadId ?? providerMessageId)),
                    sentAt: sentAt, providerMessageID: providerMessageId, providerAccountEmail: identity.email,
                    providerThreadID: providerThreadId, bodyHTML: htmlBody, providerLabelIDs: providerLabels,
                    unsubscribeHeaders: listUnsubscribe.isEmpty ? nil : MailUnsubscribeHeaders(
                        listUnsubscribe: listUnsubscribe, listUnsubscribePost: listUnsubscribePost,
                        authenticationResults: [], dkimSignatures: [], source: identity.provider))
        message.backendMessageID = id
        message.rfcMessageID = rfcMessageId
        message.inReplyTo = inReplyTo
        message.references = references ?? []
        message.providerCategories = categories
        message.hasMailingListID = hasMailingListId
        message.envelopeDetails = envelopeDetails
        return message
    }

    private static func localID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

nonisolated struct ProviderLabel: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
}

nonisolated struct MessageLabelSelection: Decodable, Sendable {
    var labels: [ProviderLabel]
    var appliedLabelIds: Set<String>

    @concurrent func sortedByName() async -> Self {
        var result = self
        result.labels.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    @concurrent static func preview(labels: [ProviderLabel], labelIDs: [String], categories: [String]?, outlook: Bool) async -> Self {
        var result = Self(labels: labels, appliedLabelIds: [])
        result.updateMembership(labelIDs: labelIDs, categories: categories, outlook: outlook)
        return result
    }

    mutating func updateMembership(from updated: BackendMailMessage, outlook: Bool) {
        updateMembership(labelIDs: updated.providerLabels, categories: updated.categories, outlook: outlook)
    }

    private mutating func updateMembership(labelIDs: [String], categories: [String]?, outlook: Bool) {
        if outlook {
            let names = Set((categories ?? []).map { $0.lowercased() })
            appliedLabelIds = Set(labels.filter { names.contains($0.name.lowercased()) }.map(\.id))
        } else {
            appliedLabelIds = Set(labelIDs).intersection(labels.map(\.id))
        }
    }
}

nonisolated struct CreateProviderLabel: Encodable, Sendable { let name: String }
nonisolated struct SetProviderLabel: Encodable, Sendable {
    let labelId: String
    let applied: Bool
}
