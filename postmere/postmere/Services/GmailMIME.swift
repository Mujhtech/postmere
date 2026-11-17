import Foundation

nonisolated struct GmailOutgoingAttachment: Sendable {
    let name: String
    let mimeType: String
    let data: Data
}

nonisolated struct GmailOutgoingMail: Sendable {
    let from: String
    let displayName: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let plainText: String
    let html: String?
    let messageID: String
    let inReplyTo: String?
    let references: [String]
    let attachments: [GmailOutgoingAttachment]
}

/// Emits RFC 5322 / MIME bytes. Google's API accepts their base64url representation.
/// https://developers.google.com/workspace/gmail/api/guides/sending
nonisolated enum GmailMIME {
    static func encode(_ mail: GmailOutgoingMail, now: Date = .now) throws -> Data {
        let recipients = mail.to + mail.cc + mail.bcc
        guard !recipients.isEmpty else { throw GmailError.invalidMessage("Add at least one recipient before sending.") }
        for address in [mail.from] + recipients {
            guard address.range(of: #"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil,
                  !address.contains("..") else { throw GmailError.invalidMessage("Check this email address: \(address)") }
        }
        for value in [mail.subject, mail.displayName, mail.messageID] + [mail.inReplyTo].compactMap({ $0 }) + mail.references {
            guard !value.unicodeScalars.contains(where: { [0, 10, 13].contains($0.value) }) else {
                throw GmailError.invalidMessage("An email header contains an unexpected line break. Edit the subject or recipients and try again.")
            }
        }
        guard isMessageID(mail.messageID), mail.inReplyTo.map(isMessageID) != false, mail.references.allSatisfy(isMessageID) else {
            throw GmailError.invalidMessage("The email’s conversation headers are invalid. Start a new message to send it safely.")
        }
        guard mail.attachments.reduce(0, { $0 + $1.data.count }) <= 25 * 1_024 * 1_024 else {
            throw GmailError.invalidMessage("Keep attachments under 25 MB combined before sending with Gmail.")
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var headers = ["From: \(mail.displayName.isEmpty ? mail.from : encodedWords(mail.displayName) + " <\(mail.from)>")",
                       "Date: \(dateFormatter.string(from: now))", "Message-ID: \(mail.messageID)",
                       "Subject: \(encodedWords(mail.subject))", "MIME-Version: 1.0"]
        for (name, addresses) in [("To", mail.to), ("Cc", mail.cc), ("Bcc", mail.bcc)] where !addresses.isEmpty {
            headers.append("\(name): \(addresses.joined(separator: ",\r\n "))")
        }
        if let inReplyTo = mail.inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        if !mail.references.isEmpty { headers.append("References: \(mail.references.joined(separator: "\r\n "))") }

        let content: String
        if mail.attachments.isEmpty {
            content = bodyPart(plain: mail.plainText, html: mail.html)
        } else {
            let boundary = "postmere_mixed_\(UUID().uuidString)"
            var parts = [bodyPart(plain: mail.plainText, html: mail.html)]
            for attachment in mail.attachments {
                let mime = attachment.mimeType.range(of: #"^[A-Za-z0-9.+_-]+/[A-Za-z0-9.+_-]+$"#, options: .regularExpression) != nil
                    ? attachment.mimeType : "application/octet-stream"
                // RFC 2231 provides the Unicode filename without permitting MIME header injection.
                let safeName = attachment.name.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")
                let encodedName = safeName.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
                parts.append("Content-Type: \(mime)\r\nContent-Disposition: attachment;\r\n filename*=UTF-8''\(encodedName)\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64Lines(attachment.data))")
            }
            content = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
                + parts.map { "--\(boundary)\r\n\($0)\r\n" }.joined() + "--\(boundary)--\r\n"
        }
        let data = Data((headers.joined(separator: "\r\n") + "\r\n" + content).utf8)
        guard data.count <= 35 * 1_024 * 1_024 else { throw GmailError.invalidMessage("This message is too large for Gmail. Remove an attachment and try again.") }
        return data
    }

    static func isMessageID(_ string: String) -> Bool {
        string.range(of: #"^<[^<>\s@]+@[^<>\s@]+>$"#, options: .regularExpression) != nil
    }

    private static func bodyPart(plain: String, html: String?) -> String {
        let plainPart = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64Lines(Data(crlf(plain).utf8)))"
        guard let html, !html.isEmpty else { return plainPart + "\r\n" }
        let boundary = "postmere_alt_\(UUID().uuidString)"
        let htmlPart = "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64Lines(Data(crlf(html).utf8)))"
        return "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n--\(boundary)\r\n\(plainPart)\r\n--\(boundary)\r\n\(htmlPart)\r\n--\(boundary)--\r\n"
    }

    private static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    private static func crlf(_ string: String) -> String {
        string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func encodedWords(_ string: String) -> String {
        guard !string.isEmpty else { return "" }
        var chunks: [String] = []; var chunk = ""
        for scalar in string.unicodeScalars {
            let next = String(scalar)
            if (chunk + next).utf8.count > 42 { chunks.append(chunk); chunk = "" }
            chunk += next
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
}
