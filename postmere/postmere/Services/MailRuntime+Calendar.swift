import Foundation

extension MailRuntime {
    func calendarInvitationBytes(attachment: MailAttachment?, message: MailMessage) async throws -> Data {
        if let attachment {
            if let data = attachment.inlineCalendarData { return data }
            if let url = attachment.localURL, let data = try? await MailCalendarInvitationParser.readFile(url) { return data }
            guard (attachment.byteCount ?? 0) <= MailAttachment.maximumCalendarBytes else { throw MailCalendarError.invitationTooLarge }
        }
        guard let identity = message.mailAccount.remote, backend.isAccountConnected(identity.accountID, scope: identity.scope),
              let messageID = message.backendMessageID else { throw BackendError.notConnected }
        let suffix: String
        if let attachment {
            guard let id = attachment.providerAttachmentID.flatMap(UUID.init(uuidString:)) else { throw MailCalendarError.invalidInvitation }
            suffix = "attachments/\(id.uuidString)"
        } else { suffix = "calendar-invitation" }
        let key = "\(identity.localID)/\(messageID)/\(suffix)" as NSString
        if let cached = invitationData.object(forKey: key), cached.expires > .now {
            guard let data = cached.data else { throw BackendError.response(404, "Calendar invitation unavailable") }
            return data
        }
        let data: Data
        do { data = try await backend.bytes("/v1/mail/messages/\(messageID.uuidString)/\(suffix)") }
        catch BackendError.response(404, _) where attachment == nil {
            invitationData.setObject(MailInvitationBytes(nil), forKey: key)
            throw BackendError.response(404, "Calendar invitation unavailable")
        }
        try Task.checkCancellation()
        guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { throw BackendError.notConnected }
        guard data.count <= MailAttachment.maximumCalendarBytes else { throw MailCalendarError.invitationTooLarge }
        invitationData.setObject(MailInvitationBytes(data), forKey: key, cost: data.count)
        return data
    }
}

final class MailInvitationBytes {
    let data: Data?
    let expires = Date.now.addingTimeInterval(300)
    init(_ data: Data?) { self.data = data }
}
