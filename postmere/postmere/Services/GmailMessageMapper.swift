import Foundation
import UniformTypeIdentifiers

@MainActor
enum GmailMessageMapper {
    static func message(_ wire: GmailWireMessage, accountEmail: String) -> MailMessage {
        let headers = wire.payload
        let from = GmailEncoding.decodeHeader(headers?.header("From") ?? "")
        let address = MailAddressList(from).addresses.first ?? from
        var name = from
        if let opening = from.lastIndex(of: "<") { name = String(from[..<opening]).trimmingCharacters(in: .whitespacesAndNewlines) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if name.isEmpty { name = address }
        let subject = GmailEncoding.decodeHeader(headers?.header("Subject") ?? "(No subject)")
        let labels = wire.labelIds ?? []
        let date = Date(timeIntervalSince1970: (Double(wire.internalDate ?? "") ?? 0) / 1_000)
        let mailbox: Mailbox = labels.contains("TRASH") ? .trash : labels.contains("DRAFT") ? .drafts
            : labels.contains("INBOX") ? .inbox : labels.contains("SENT") ? .sent : .archive
        let parts = wire.payload.map(displayParts) ?? []
        let text = parts.filter { !$0.isAttachment && $0.mimeType?.lowercased() == "text/plain" }.compactMap(decodeBody).joined(separator: "\n\n")
        let html = parts.filter { !$0.isAttachment && $0.mimeType?.lowercased() == "text/html" }.compactMap(decodeBody).joined(separator: "\n\n")
        let body = !text.isEmpty ? text : GmailEncoding.plainText(fromHTML: html)
        let paragraphs = body.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let attachments = parts.filter(\.isAttachment).map { part in
            let fileExtension = part.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            let fallbackName = "Attachment" + (fileExtension.map { ".\($0)" } ?? "")
            let name = GmailEncoding.decodeHeader((part.filename ?? "").isEmpty ? fallbackName : part.filename!)
            let size = part.body?.size ?? 0
            var attachment = MailAttachment(name: name, detail: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            attachment.id = GmailEncoding.stableID("gmail:\(accountEmail):\(wire.id):\(part.partId ?? name)")
            attachment.providerAttachmentID = part.body?.attachmentId ?? "inline:\(part.partId ?? "")"
            attachment.providerMessageID = wire.id
            attachment.providerAccountEmail = accountEmail
            attachment.mimeType = part.mimeType
            attachment.byteCount = size
            return attachment
        }
        let rfcID = headers?.header("Message-ID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = (headers?.header("References") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let timeFormatter = DateFormatter(); timeFormatter.timeStyle = .short
        let dateFormatter = DateFormatter(); dateFormatter.dateStyle = .medium
        let initials = name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let listHeaders = headers?.headers?.filter { $0.name.caseInsensitiveCompare("List-Unsubscribe") == .orderedSame }.map(\.value) ?? []
        let unsubscribeHeaders = listHeaders.isEmpty ? nil : MailUnsubscribeHeaders(
            listUnsubscribe: listHeaders,
            listUnsubscribePost: headers?.headers?.filter { $0.name.caseInsensitiveCompare("List-Unsubscribe-Post") == .orderedSame }.map(\.value) ?? [],
            authenticationResults: headers?.headers?.filter { $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame }.map(\.value) ?? [],
            dkimSignatures: headers?.headers?.filter { $0.name.caseInsensitiveCompare("DKIM-Signature") == .orderedSame }.map(\.value) ?? [],
            source: "gmail")
        return MailMessage(
            id: GmailEncoding.stableID("gmail:\(accountEmail):message:\(wire.id)"),
            sender: name, senderEmail: address, initials: String(initials.prefix(2)), subject: subject,
            preview: GmailEncoding.plainText(fromHTML: wire.snippet ?? String(body.prefix(180))), paragraphs: paragraphs,
            dateLabel: Calendar.current.isDateInToday(date) ? "Today" : dateFormatter.string(from: date),
            timeLabel: timeFormatter.string(from: date), isUnread: labels.contains("UNREAD"), isStarred: labels.contains("STARRED"),
            mailbox: mailbox, account: MailAccount.gmail.rawValue, tint: "8BA794", isOutgoing: labels.contains("SENT") || labels.contains("DRAFT"),
            trashedFrom: mailbox == .trash ? (labels.contains("SENT") ? .sent : .inbox) : nil,
            toRecipients: MailAddressList(headers?.header("To") ?? "").addresses,
            ccRecipients: MailAddressList(headers?.header("Cc") ?? "").addresses,
            bccRecipients: MailAddressList(headers?.header("Bcc") ?? "").addresses,
            attachments: attachments, conversationID: GmailEncoding.stableID("gmail:\(accountEmail):thread:\(wire.threadId ?? wire.id)"),
            sentAt: date, providerMessageID: wire.id, providerAccountEmail: accountEmail, providerThreadID: wire.threadId, rfcMessageID: rfcID,
            inReplyTo: headers?.header("In-Reply-To"), references: references, bodyHTML: html.isEmpty ? nil : html, providerLabelIDs: labels,
            unsubscribeHeaders: unsubscribeHeaders)
    }

    static func inlineAttachment(_ partID: String, in wire: GmailWireMessage) -> Data? {
        guard let payload = wire.payload,
              let encoded = flatten(payload).first(where: { ($0.partId ?? "") == partID })?.body?.data else { return nil }
        return GmailEncoding.decodeBase64URL(encoded)
    }

    private static func flatten(_ part: GmailMessagePart) -> [GmailMessagePart] {
        [part] + (part.parts ?? []).flatMap(flatten)
    }

    /// An attached .eml is a file; its descendants belong to that file, not the parent message.
    private static func displayParts(_ part: GmailMessagePart) -> [GmailMessagePart] {
        if part.isAttachment { return [part] }
        return [part] + (part.parts ?? []).flatMap(displayParts)
    }

    private static func decodeBody(_ part: GmailMessagePart) -> String? {
        guard let encoded = part.body?.data, let data = GmailEncoding.decodeBase64URL(encoded) else { return nil }
        let contentType = part.header("Content-Type") ?? ""
        let charset = contentType.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("charset=") }?.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return GmailEncoding.decodeText(data, charset: charset)
    }
}
