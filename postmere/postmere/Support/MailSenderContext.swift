import Foundation

enum MailContactIdentity {
    static func email(_ value: String) -> String {
        let parsed = MailAddressList(value)
        return (parsed.addresses.count == 1 ? parsed.addresses[0] : value)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Keeps workspace/provider account identity in the scope, including when
    /// the same email address is connected in more than one workspace.
    static func accountKey(account: String, providerAccountEmail: String?) -> String {
        "\(account.count)#\(account)\(providerAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")"
    }

    static func accountKey(for message: MailMessage) -> String {
        accountKey(account: message.account, providerAccountEmail: message.providerAccountEmail)
    }

    static func scope(from key: String) -> (account: String, providerEmail: String?)? {
        guard let marker = key.firstIndex(of: "#"), let length = Int(key[..<marker]), length > 0 else { return nil }
        let start = key.index(after: marker)
        guard let end = key.index(start, offsetBy: length, limitedBy: key.endIndex) else { return nil }
        let account = String(key[start..<end])
        let provider = String(key[end...])
        return (account, provider.isEmpty ? nil : provider)
    }
}

struct MailContactConversation: Identifiable {
    let id: String
    let latestMessage: MailMessage
    let messageCount: Int
}

struct MailContactAttachment: Identifiable {
    let attachment: MailAttachment
    let message: MailMessage
    var id: String { "\(message.id.uuidString)|\(attachment.id.uuidString)" }
}

struct MailSenderContext {
    let email: String
    let accountKey: String
    let conversations: [MailContactConversation]
    let attachments: [MailContactAttachment]
    let messageCount: Int
    let lastContact: Date?

    static func build(email: String, accountKey: String, messages: [MailMessage]) -> Self {
        let email = MailContactIdentity.email(email)
        let related = messages.filter { message in
            guard MailContactIdentity.accountKey(for: message) == accountKey,
                  !message.isDraft, message.mailbox != .outbox, message.mailbox != .trash, !message.isDeletedOnProvider else { return false }
            let participants = [message.senderEmail] + message.toRecipients + message.ccRecipients + (message.isOutgoing ? message.bccRecipients : [])
            return participants.contains { MailContactIdentity.email($0) == email }
        }.sorted { $0.sentAt > $1.sentAt }
        let groups = Dictionary(grouping: related) { "\(accountKey)|\($0.conversationID.uuidString)" }
        let conversations = groups.compactMap { key, items -> MailContactConversation? in
            guard let newest = items.max(by: { $0.sentAt < $1.sentAt }) else { return nil }
            return MailContactConversation(id: key, latestMessage: newest, messageCount: items.count)
        }.sorted { $0.latestMessage.sentAt > $1.latestMessage.sentAt }
        let attachments = related.flatMap { message in message.attachments.map { MailContactAttachment(attachment: $0, message: message) } }
        return Self(email: email, accountKey: accountKey, conversations: conversations, attachments: attachments,
                    messageCount: related.count, lastContact: related.first?.sentAt)
    }
}

struct MailRecipientSuggestion: Identifiable, Equatable {
    let email: String
    let name: String
    let messageCount: Int
    let lastContact: Date
    var id: String { email }
}

enum MailRecipientSuggestions {
    private struct Candidate {
        var email: String
        var name: String
        var messages: Set<UUID> = []
        var outgoingCount = 0
        var lastContact: Date
    }

    static func suggestions(for input: String, messages: [MailMessage], accountKey: String,
                            excluding: [String] = [], ownAddresses: [String] = [], limit: Int = 6,
                            now: Date = .now) -> [MailRecipientSuggestion] {
        let query = currentToken(in: input).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let excluded = Set((excluding + ownAddresses).map { MailContactIdentity.email($0) })
        var candidates: [String: Candidate] = [:]
        for message in messages {
            guard MailContactIdentity.accountKey(for: message) == accountKey, !message.isDraft,
                  message.mailbox != .outbox, message.mailbox != .trash, !message.isDeletedOnProvider,
                  message.isOutgoing || message.workflow.screeningState == .accepted else { continue }
            var participants: [(String, String)] = [(message.senderEmail, message.sender)]
            participants += (message.toRecipients + message.ccRecipients + (message.isOutgoing ? message.bccRecipients : [])).map { ($0, "") }
            for (raw, name) in participants {
                let parsed = MailAddressList(raw)
                guard parsed.invalid.isEmpty, parsed.addresses.count == 1 else { continue }
                let email = parsed.addresses[0].lowercased()
                guard !excluded.contains(email) else { continue }
                var candidate = candidates[email] ?? Candidate(email: email, name: name, lastContact: message.sentAt)
                if candidate.name.isEmpty, !name.isEmpty { candidate.name = name }
                if candidate.messages.insert(message.id).inserted, message.isOutgoing { candidate.outgoingCount += 1 }
                candidate.lastContact = max(candidate.lastContact, message.sentAt)
                candidates[email] = candidate
            }
        }
        func score(_ candidate: Candidate) -> Double {
            let prefix = !query.isEmpty && (candidate.email.hasPrefix(query) || candidate.name.lowercased().hasPrefix(query)) ? 1000.0 : 0
            let days = max(0, now.timeIntervalSince(candidate.lastContact) / 86_400)
            return prefix + Double(candidate.messages.count + candidate.outgoingCount * 3) + 30 / (days + 1)
        }
        return candidates.values.filter { query.isEmpty || $0.email.contains(query) || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in score(lhs) == score(rhs) ? lhs.email < rhs.email : score(lhs) > score(rhs) }
            .prefix(max(0, min(20, limit))).map {
                MailRecipientSuggestion(email: $0.email, name: $0.name, messageCount: $0.messages.count, lastContact: $0.lastContact)
            }
    }

    static func currentToken(in input: String) -> String { String(input[tokenStart(in: input)...]) }

    static func replacingCurrentToken(in input: String, with suggestion: MailRecipientSuggestion) -> String {
        let prefix = String(input[..<tokenStart(in: input)])
        return prefix + (prefix.isEmpty ? "" : " ") + suggestion.email + ", "
    }

    private static func tokenStart(in input: String) -> String.Index {
        var quoted = false
        var angled = false
        var escaped = false
        var result = input.startIndex
        for index in input.indices {
            let character = input[index]
            if escaped { escaped = false; continue }
            if character == "\\", quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if character == "<", !quoted { angled = true }
            if character == ">", !quoted { angled = false }
            if !quoted, !angled, character == "," || character == ";" || character.isNewline { result = input.index(after: index) }
        }
        return result
    }
}
