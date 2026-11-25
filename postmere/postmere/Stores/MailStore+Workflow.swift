import Foundation

extension MailStore {
    var selectedSavedView: SavedInboxView? { savedViews.first { $0.id == selectedSavedViewID } }
    func isAccountVisible(_ message: MailMessage) -> Bool {
        matchesActiveProviderAccount(message) && (!message.isDeletedOnProvider || message.isDraft || message.mailbox == .outbox)
    }

    func conversationKey(for message: MailMessage) -> String {
        message.searchConversationKey
    }

    func deduplicatedConversations(_ candidates: [MailMessage]) -> [MailMessage] {
        MailSearchRequest.representatives(candidates, preferred: selectedMessageID)
    }

    func matchesActiveProviderAccount(_ message: MailMessage) -> Bool {
        if message.mailAccount.isRemote { return message.mailAccount.remote != nil }
        return isPreview && message.mailAccount != .gmail && message.mailAccount != .unassigned
    }

    nonisolated func sameMailAccount(_ first: MailMessage, _ second: MailMessage) -> Bool {
        guard first.account == second.account else { return false }
        if first.account.hasPrefix("remote:") { return true }
        guard let firstEmail = first.providerAccountEmail, let secondEmail = second.providerAccountEmail else { return true }
        return firstEmail.caseInsensitiveCompare(secondEmail) == .orderedSame
    }

    func matchesMailbox(_ message: MailMessage, mailbox: Mailbox, now: Date = .now) -> Bool {
        guard isAccountVisible(message) else { return false }
        return message.belongs(to: mailbox)
    }

    func matchesSavedView(_ message: MailMessage, criteria: SavedInboxCriteria) -> Bool {
        guard isAccountVisible(message) else { return false }
        return MailCriteriaMatcher(criteria: criteria, query: parsedQuery(criteria.query, field: criteria.searchField))
            .matches(message, context: searchContext)
    }

    func selectSavedView(_ view: SavedInboxView) {
        selectedMailbox = .inbox
        selectedAccount = nil
        clearFilters()
        selectedSavedViewID = view.id
        showMailboxOverview()
    }

    func selectSavedView(_ id: UUID) {
        if let view = savedViews.first(where: { $0.id == id }) { selectSavedView(view) }
    }

    @discardableResult
    func saveInboxView(name: String, criteria: SavedInboxCriteria) -> SavedInboxView {
        let view = SavedInboxView(name: name.trimmingCharacters(in: .whitespacesAndNewlines), criteria: criteria)
        savedViews.append(view)
        return view
    }

    func saveInboxView(_ view: SavedInboxView) {
        if let index = savedViews.firstIndex(where: { $0.id == view.id }) { savedViews[index] = view }
        else { savedViews.append(view) }
    }

    func deleteSavedView(_ id: UUID) {
        savedViews.removeAll { $0.id == id }
        if selectedSavedViewID == id { selectMailbox(.inbox) }
    }

    func saveSnippet(_ snippet: MailSnippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = snippet }
        else { snippets.append(snippet) }
    }

    func upsertSnippet(_ snippet: MailSnippet) { saveSnippet(snippet) }
    func deleteSnippet(_ id: UUID) { snippets.removeAll { $0.id == id } }

    func updateConversation(containing id: UUID, _ update: (inout MailMessage) -> Void) {
        guard let selected = messages.first(where: { $0.id == id }) else { return }
        var updated = messages
        for index in updated.indices where updated[index].conversationID == selected.conversationID
            && sameMailAccount(updated[index], selected) && (updated[index].mailbox == .junk) == (selected.mailbox == .junk) {
            update(&updated[index])
        }
        messages = updated
        reconcileSelection()
    }

    func setNeedsReply(_ needsReply: Bool, for id: UUID) {
        let decision = Date.now
        updateConversation(containing: id) {
            $0.workflow.needsReply = needsReply
            $0.workflow.replyDecisionAt = max(decision, $0.sentAt)
            $0.automaticReplyPending = nil
        }
        lastAction = needsReply ? "Added to Needs Reply" : "Marked done"
    }

    func snoozeMessage(_ id: UUID, until date: Date) {
        guard date > .now else { unsnoozeMessage(id); return }
        let open = selectedMessage
        let conversation = messages.first { $0.id == id }?.conversationID
        updateConversation(containing: id) { $0.workflow.snoozedUntil = date }
        if let open, open.conversationID == conversation, selectedMessageID != open.id {
            departure = MailDeparture(messageID: open.id, destination: .snoozed, subject: open.displaySubject)
        }
        lastAction = "Conversation snoozed"
    }

    func unsnoozeMessage(_ id: UUID) {
        updateConversation(containing: id) { message in
            message.workflow.snoozedUntil = nil
            if message.mailbox == .archive && !message.isDeletedOnProvider { message.mailbox = .inbox }
        }
        lastAction = "Returned to Inbox"
    }

    func setFollowUp(_ id: UUID, at date: Date, onlyIfNoReply: Bool = true) {
        updateConversation(containing: id) { message in
            message.workflow.followUpAt = date
            message.workflow.followUpOnlyIfNoReply = onlyIfNoReply
            message.workflow.followUpReferenceDate = .now
        }
        lastAction = "Follow-up reminder set"
    }

    func clearFollowUp(_ id: UUID) {
        updateConversation(containing: id) {
            $0.workflow.followUpAt = nil
            $0.workflow.followUpReferenceDate = nil
        }
        lastAction = "Follow-up cleared"
    }

    func followUpIsDue(_ message: MailMessage, now: Date = .now) -> Bool {
        message.workflow.followUpAt.map { $0 <= now } ?? false
    }

    func setPrivateNote(_ note: String, for id: UUID) {
        updateConversation(containing: id) { $0.workflow.privateNote = note }
    }

    func saveSenderRule(_ rule: SenderRule, applyToExisting: Bool = true) {
        var normalized = rule
        normalized.email = rule.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = senderRules.firstIndex(where: { $0.id == rule.id || ($0.email == normalized.email && $0.account == rule.account && $0.providerAccountEmail == rule.providerAccountEmail) }) {
            senderRules[index] = normalized
        } else { senderRules.append(normalized) }
        guard applyToExisting else { return }
        var updated = messages
        let rules = senderRules
        for index in updated.indices where matchesRule(normalized, message: updated[index]) && !updated[index].isOutgoing && !updated[index].isDeletedOnProvider {
            // A domain rule settles mail still waiting for screening; it never
            // moves mail already filed, or overrides a rule for one address.
            if normalized.domain != nil {
                guard updated[index].workflow.screeningState == .pending,
                      SenderRule.first(in: rules, where: { matchesRule($0, message: updated[index]) }) == normalized else { continue }
            }
            applyRule(normalized, to: &updated[index])
        }
        MailReplyQueue.reconcile(&updated)
        messages = updated
        reconcileSelection()
    }

    func deleteSenderRule(_ id: UUID) { senderRules.removeAll { $0.id == id } }

    func acceptSender(of message: MailMessage, route: SenderRoute = .inbox) {
        decideSender(SenderRule(email: message.senderEmail, account: message.account, route: route, providerAccountEmail: message.providerAccountEmail))
        lastAction = "Sender accepted · \(route.title)"
    }

    /// Saves a screening decision. When it takes the open message out of the
    /// list (New Senders, or Trash for a block), the reader plays the same
    /// departure as Archive or Move instead of swapping instantly.
    private func decideSender(_ rule: SenderRule) {
        if let open = selectedMessage, selectedMessageIDs.count <= 1,
           open.workflow.screeningState == .pending, matchesRule(rule, message: open),
           selectedMailbox == .newSenders || rule.route == .blocked {
            let destination: Mailbox = switch rule.route {
            case .inbox, .needsReply: .inbox
            case .archive: .archive
            case .blocked: .trash
            }
            departure = MailDeparture(messageID: open.id, destination: destination, subject: open.displaySubject)
        }
        saveSenderRule(rule)
    }

    /// Allows every address at the sender's domain, such as jobs-noreply@ and
    /// jobalerts-noreply@linkedin.com. Only offered when the person asks.
    func acceptDomain(_ domain: String, of message: MailMessage, route: SenderRoute = .inbox) {
        decideSender(.domain(domain, account: message.account, route: route, providerAccountEmail: message.providerAccountEmail))
        lastAction = "Everyone at \(domain) accepted · \(route.title)"
    }

    func blockSender(of message: MailMessage) {
        decideSender(SenderRule(email: message.senderEmail, account: message.account, route: .blocked, providerAccountEmail: message.providerAccountEmail))
        lastAction = "Sender blocked"
    }

    nonisolated func matchesRule(_ rule: SenderRule, message: MailMessage) -> Bool {
        rule.matches(senderEmail: message.senderEmail) && (rule.account == nil || rule.account == message.account)
            && (rule.providerAccountEmail == nil || rule.providerAccountEmail?.lowercased() == message.providerAccountEmail?.lowercased())
    }

    func permitsIncomingNotification(_ message: MailMessage) -> Bool {
        guard message.isUnread, !message.isOutgoing, !message.isDeletedOnProvider, message.mailbox == .inbox else { return false }
        if let rule = SenderRule.first(in: senderRules, where: { matchesRule($0, message: message) }) {
            return rule.route == .inbox || rule.route == .needsReply
        }
        return !senderScreeningEnabled
    }

    nonisolated func applyRule(_ rule: SenderRule, to message: inout MailMessage) {
        guard message.mailbox != .junk else { return }
        message.workflow.screeningState = rule.route == .blocked ? .blocked : .accepted
        // Routing never revives mail that was explicitly trashed, except an accepted screened sender.
        guard message.mailbox != .trash || message.workflow.screeningState == .blocked else { return }
        switch rule.route {
        case .inbox: message.mailbox = .inbox
        case .archive: message.mailbox = .archive
        case .needsReply: message.mailbox = .inbox; message.workflow.needsReply = true
        case .blocked:
            if message.mailbox != .trash { message.trashedFrom = message.mailbox }
            message.mailbox = .trash
        }
    }

    var notificationSchedules: [MailNotificationSchedule] {
        var result: [String: MailNotificationSchedule] = [:]
        for message in messages where isAccountVisible(message) && !message.isDraft && !message.mailbox.isJunkOrTrash && message.mailbox != .outbox {
            if let date = message.workflow.snoozedUntil {
                let item = MailNotificationSchedule(conversationID: message.conversationID, messageID: message.id, title: message.subject, date: date, kind: .snooze)
                result[item.id] = item
            }
            if let date = message.workflow.followUpAt {
                let item = MailNotificationSchedule(conversationID: message.conversationID, messageID: message.id, title: message.subject, date: date, kind: .followUp)
                result[item.id] = item
            }
        }
        return result.values.sorted { $0.date < $1.date }
    }
}

extension MailStore {
    /// The unfiltered inbox uses the daily overview. Other views display their own title.
    var overviewTitle: String? {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Search results" }
        if let view = selectedSavedView { return view.name }
        if selectedMailbox == .inbox {
            if let split = visibleInboxSplits.first(where: { $0.id == selectedInboxSplitID }) { return split.name }
            if !unreadOnly && !attachmentsOnly { return nil }
        }
        return selectedMailbox.title
    }
}

nonisolated struct InboxOverview: Sendable {
    struct Section: Identifiable, Sendable {
        let title: String
        let count: Int
        let messages: [MailMessage]
        /// Every conversation in the section, in order, for triage.
        let allIDs: [UUID]
        let mailbox: Mailbox?
        var id: String { title }

        init(title: String, messages: [MailMessage], mailbox: Mailbox?) {
            self.title = title
            self.count = messages.count
            self.allIDs = messages.map(\.id)
            self.messages = Array(messages.prefix(3))
            self.mailbox = mailbox
        }
    }

    let isInbox: Bool
    let title: String
    let summary: String
    let sections: [Section]
    /// All unread conversations, including those listed in an earlier section.
    let unreadCount: Int

    @MainActor init(store: MailStore) {
        self.init(messages: store.messages, visible: store.filteredMessages, request: store.searchRequest(), title: store.overviewTitle)
    }

    init(messages: [MailMessage], visible: [MailMessage], request: MailSearchRequest, title: String?) {
        func conversations(in candidates: [MailMessage]) -> [MailMessage] {
            MailSearchRequest.representatives(candidates, preferred: request.selectedID)
        }
        isInbox = title == nil
        self.title = title ?? ""
        if title != nil {
            let conversations = conversations(in: visible).sorted { $0.sentAt > $1.sentAt }
            summary = conversations.isEmpty ? "No conversations in this view." : Self.count(conversations.count, singular: "conversation", plural: "conversations")
            sections = conversations.isEmpty ? [] : [Section(title: "Recent conversations", messages: conversations, mailbox: nil)]
            unreadCount = conversations.count(where: \.isUnread)
            return
        }

        let scoped = messages.filter(request.visible)
        func queue(_ mailbox: Mailbox) -> [MailMessage] {
            conversations(in: scoped.filter { $0.belongs(to: mailbox) })
        }
        let waiting = queue(.needsReply).sorted { $0.sentAt > $1.sentAt }
        let reminders = queue(.followUps).sorted { ($0.workflow.followUpAt ?? .distantFuture) < ($1.workflow.followUpAt ?? .distantFuture) }
        let unread = conversations(in: visible.filter(\.isUnread)).sorted { $0.sentAt > $1.sentAt }
        unreadCount = unread.count
        var counts: [String] = []
        if !waiting.isEmpty { counts.append(Self.count(waiting.count, singular: "conversation needs a reply", plural: "conversations need a reply")) }
        if !unread.isEmpty { counts.append(Self.count(unread.count, singular: "unread conversation", plural: "unread conversations")) }
        if !reminders.isEmpty { counts.append(Self.count(reminders.count, singular: "follow-up", plural: "follow-ups")) }
        summary = counts.isEmpty ? "You’re all caught up." : counts.joined(separator: " · ")

        var groups: [Section] = []
        if !waiting.isEmpty { groups.append(Section(title: "Needs reply", messages: waiting, mailbox: .needsReply)) }
        if !reminders.isEmpty { groups.append(Section(title: "Follow-ups", messages: reminders, mailbox: .followUps)) }
        let quiet = MailNudges.waiting(in: scoped, excluding: Set((waiting + reminders).map(\.searchConversationKey)))
        if !quiet.isEmpty { groups.append(Section(title: "No reply yet", messages: quiet, mailbox: nil)) }
        let alreadyListed = Set((waiting + reminders + quiet).map(\.searchConversationKey))
        let otherUnread = unread.filter { !alreadyListed.contains($0.searchConversationKey) }
        if !otherUnread.isEmpty {
            groups.append(Section(title: otherUnread.count < unread.count ? "Other unread" : "Unread",
                                  messages: otherUnread, mailbox: .inbox))
        } else if groups.isEmpty && !visible.isEmpty {
            let conversations = conversations(in: visible).sorted { $0.sentAt > $1.sentAt }
            groups.append(Section(title: "Recent conversations", messages: conversations, mailbox: nil))
        }
        sections = groups
    }

    private static func count(_ n: Int, singular: String, plural: String) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural)"
    }
}

/// Conversations where the user asked something and nobody has answered: the
/// newest message is theirs, a few days old, and reads like it expects a reply.
/// Found on the device; nothing is sent anywhere to decide this.
nonisolated enum MailNudges {
    static let minimumAge: TimeInterval = 3 * 86_400
    static let maximumAge: TimeInterval = 30 * 86_400

    nonisolated static func waiting(in messages: [MailMessage], excluding: Set<String> = [], now: Date = .now) -> [MailMessage] {
        var newest: [String: MailMessage] = [:]
        for message in messages where !message.isDraft && message.mailbox != .outbox && message.mailbox != .trash
            && message.mailbox != .junk && !message.isDeletedOnProvider {
            let key = message.searchConversationKey
            if let current = newest[key], current.sentAt >= message.sentAt { continue }
            newest[key] = message
        }
        return newest.values
            .filter { message in
                let age = now.timeIntervalSince(message.sentAt)
                return message.isOutgoing && age >= minimumAge && age <= maximumAge
                    && !excluding.contains(message.searchConversationKey)
                    && message.workflow.followUpAt == nil && expectsReply(message)
            }
            .sorted { $0.sentAt > $1.sentAt }
    }

    /// A question or a request in what the user wrote, not in the quoted history below it.
    nonisolated static func expectsReply(_ message: MailMessage) -> Bool {
        var own: [String] = []
        for line in message.paragraphs.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") || (trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:")) { break }
            own.append(trimmed)
        }
        let text = own.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return false }
        if text.contains("?") { return true }
        return ["let me know", "please confirm", "could you", "can you", "would you", "please send", "please share",
                "get back to me", "look forward to hearing", "awaiting your", "your thoughts", "please advise"]
            .contains { text.contains($0) }
    }
}

extension MailStore {
    /// Records triage priorities on messages in one update. Local only: nothing
    /// is sent to the mail provider.
    func applyTriagePriorities(_ priorities: [UUID: String]) {
        var updated = messages
        var changed = false
        for index in updated.indices {
            // A conversation marked done stays done when suggestions are fetched again.
            guard let priority = priorities[updated[index].id], updated[index].triagePriority != priority,
                  updated[index].triagePriority != "done" else { continue }
            updated[index].triagePriority = priority
            changed = true
        }
        guard changed else { return }
        let previous = suppressRemoteMutations
        suppressRemoteMutations = true
        messages = updated
        suppressRemoteMutations = previous
    }
}

extension MailStore {
    /// Takes a conversation out of Needs you without changing its mailbox.
    func markTriageDone(conversationOf id: UUID) {
        updateConversation(containing: id) { message in
            if message.triagePriority == "needs_you" { message.triagePriority = "done" }
        }
        lastAction = "Marked done"
    }
}
