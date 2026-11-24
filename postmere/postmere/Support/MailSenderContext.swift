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
                  !message.isDraft, message.mailbox != .outbox, !message.mailbox.isJunkOrTrash, !message.isDeletedOnProvider else { return false }
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
                  message.mailbox != .outbox, !message.mailbox.isJunkOrTrash, !message.isDeletedOnProvider,
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

/// Your history with one person, from your own mail only: when you first and
/// last talked, how quickly each of you replies, what is waiting on whom, and
/// when they tend to write. Nothing here leaves the Mac.
struct MailRelationship: Equatable {
    struct Thread: Equatable, Identifiable {
        let id: UUID
        let messageID: UUID
        let subject: String
        let date: Date
    }

    var firstContact: Date?
    var lastContact: Date?
    var conversations = 0
    var fromThem = 0
    var fromYou = 0
    /// Typical time for them to answer you, and for you to answer them.
    var theirReplyTime: TimeInterval?
    var yourReplyTime: TimeInterval?
    /// Conversations whose latest message is theirs, or yours to them.
    var waitingOnYou: [Thread] = []
    var waitingOnThem: [Thread] = []
    /// The start of the two-hour window, in the given calendar's time zone,
    /// when most of their mail arrives; nil with too little to go on.
    var usualHour: Int?
    var lastSubject: String?

    var isEmpty: Bool { fromThem == 0 && fromYou == 0 }

    static func build(email: String, accountKey: String, messages: [MailMessage],
                      calendar: Calendar = .current, now: Date = .now) -> Self {
        let email = MailContactIdentity.email(email)
        func fromThem(_ message: MailMessage) -> Bool {
            !message.isOutgoing && MailContactIdentity.email(message.senderEmail) == email
        }
        func toThem(_ message: MailMessage) -> Bool {
            message.isOutgoing && (message.toRecipients + message.ccRecipients + message.bccRecipients)
                .contains { MailContactIdentity.email($0) == email }
        }
        let related = messages.filter {
            MailContactIdentity.accountKey(for: $0) == accountKey && !$0.isDraft && $0.mailbox != .outbox
                && !$0.mailbox.isJunkOrTrash && !$0.isDeletedOnProvider && (fromThem($0) || toThem($0))
        }
        var result = Self()
        guard !related.isEmpty else { return result }
        let sorted = related.sorted { $0.sentAt < $1.sentAt }
        result.firstContact = sorted.first?.sentAt
        result.lastContact = sorted.last?.sentAt
        result.lastSubject = sorted.last.map(\.displaySubject)
        result.fromThem = related.count(where: fromThem)
        result.fromYou = related.count - result.fromThem

        var theirs: [TimeInterval] = []
        var yours: [TimeInterval] = []
        let threads = Dictionary(grouping: sorted, by: \.conversationID)
        result.conversations = threads.count
        for (id, thread) in threads {
            // A reply is the first message from the other side after one from you, and vice versa.
            for (previous, next) in zip(thread, thread.dropFirst()) {
                let gap = next.sentAt.timeIntervalSince(previous.sentAt)
                guard gap > 0, gap < 60 * 86_400 else { continue }
                if toThem(previous), fromThem(next) { theirs.append(gap) }
                if fromThem(previous), toThem(next) { yours.append(gap) }
            }
            guard let latest = thread.last, now.timeIntervalSince(latest.sentAt) < 90 * 86_400 else { continue }
            let item = Thread(id: id, messageID: latest.id, subject: latest.displaySubject, date: latest.sentAt)
            if fromThem(latest), latest.mailbox == .inbox { result.waitingOnYou.append(item) }
            if toThem(latest) { result.waitingOnThem.append(item) }
        }
        func median(_ values: [TimeInterval]) -> TimeInterval? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        }
        result.theirReplyTime = median(theirs)
        result.yourReplyTime = median(yours)
        result.waitingOnYou.sort { $0.date > $1.date }
        result.waitingOnThem.sort { $0.date > $1.date }

        let hours = related.filter(fromThem).map { calendar.component(.hour, from: $0.sentAt) }
        if hours.count >= 4 {
            let windows = (0..<24).map { start in hours.count { ($0 - start + 24) % 24 < 2 } }
            if let best = windows.indices.max(by: { windows[$0] < windows[$1] }), windows[best] * 2 >= hours.count {
                result.usualHour = best
            }
        }
        return result
    }
}

extension MailRelationship {
    /// "under an hour", "about 3 hours", "about 2 days".
    static func duration(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3_600
        if hours < 1 { return "Within an hour" }
        if hours < 36 { return "About \(Int(hours.rounded())) hour\(Int(hours.rounded()) == 1 ? "" : "s")" }
        let days = Int((hours / 24).rounded())
        return "About \(days) day\(days == 1 ? "" : "s")"
    }

    /// "9–11 AM" in the current locale's hour style.
    static func window(from hour: Int) -> String {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        let end = start.addingTimeInterval(2 * 3_600)
        return (start..<end).formatted(.interval.hour())
    }
}
