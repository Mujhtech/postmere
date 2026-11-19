import Foundation

extension MailMessage {
    /// The server builds this exact MIME header from the local outbox job UUID.
    nonisolated var postmereSendID: UUID? {
        guard isOutgoing, let rfcMessageID, rfcMessageID.first == "<",
              rfcMessageID.hasSuffix("@postmere.local>") else { return nil }
        return UUID(uuidString: String(rfcMessageID.dropFirst().dropLast("@postmere.local>".count)))
    }

    nonisolated mutating func retainDownloads(from previous: MailMessage) {
        for attachment in previous.attachments where attachment.localURL != nil {
            if let index = attachments.firstIndex(where: {
                $0.id == attachment.id || (attachment.providerAttachmentID != nil && $0.providerAttachmentID == attachment.providerAttachmentID)
            }) {
                if attachments[index].localURL == nil { attachments[index].localURL = attachment.localURL }
            } else {
                attachments.append(attachment)
            }
        }
    }
}

/// Remote account keys include the workspace and provider account UUID. The
/// address is display metadata for those accounts and may be renamed upstream.
nonisolated struct MailSyncIdentity: Hashable {
    private enum Value: Hashable {
        case local(UUID)
        case backend(UUID)
        case provider(String)
    }

    private let account: String
    private let legacyAddress: String?
    private let value: Value

    private init(_ value: Value, for message: MailMessage) {
        self.value = value
        account = message.account
        legacyAddress = message.legacyAccountAddress
    }

    static func local(_ id: UUID, in message: MailMessage) -> Self { Self(.local(id), for: message) }

    static func keys(for message: MailMessage) -> [Self] {
        var keys: [Self] = []
        if let id = message.backendMessageID { keys.append(Self(.backend(id), for: message)) }
        if let id = message.providerMessageID, !id.isEmpty { keys.append(Self(.provider(id), for: message)) }
        keys.append(local(message.id, in: message))
        return keys
    }
}

/// Update the index after each delivery so a replay in the same page sees
/// the current row, including any provider identifiers learned along the way.
nonisolated struct MailMergePositions {
    private var slots: [MailSyncIdentity: Set<Int>] = [:]

    init(_ messages: [MailMessage]) {
        slots.reserveCapacity(messages.count * 3)
        for (index, message) in messages.enumerated() { insert(message, at: index) }
    }

    func matches(_ message: MailMessage) -> Set<Int> {
        var matches: Set<Int> = []
        for key in MailSyncIdentity.keys(for: message) {
            if let indices = slots[key] { matches.formUnion(indices) }
        }
        return matches
    }

    func local(_ id: UUID, in message: MailMessage) -> Int? {
        slots[.local(id, in: message)]?.first
    }

    mutating func insert(_ message: MailMessage, at index: Int) {
        for key in MailSyncIdentity.keys(for: message) { slots[key, default: []].insert(index) }
    }

    mutating func replace(_ old: MailMessage, with new: MailMessage, at index: Int) {
        let oldKeys = MailSyncIdentity.keys(for: old), newKeys = MailSyncIdentity.keys(for: new)
        guard oldKeys != newKeys else { return }
        for key in oldKeys where !newKeys.contains(key) {
            slots[key]?.remove(index)
            if slots[key]?.isEmpty == true { slots[key] = nil }
        }
        for key in newKeys where !oldKeys.contains(key) { slots[key, default: []].insert(index) }
    }
}
