import Foundation

extension MailStore {
    var selectedSavedView: SavedInboxView? { savedViews.first { $0.id == selectedSavedViewID } }
    func isAccountVisible(_ message: MailMessage) -> Bool {
        matchesActiveProviderAccount(message) && (!message.isDeletedOnProvider || message.isDraft || message.mailbox == .outbox)
    }

    func conversationKey(for message: MailMessage) -> String {
        "\(message.account)|\(message.providerAccountEmail?.lowercased() ?? "")|\(message.conversationID.uuidString)"
    }

    func deduplicatedConversations(_ candidates: [MailMessage]) -> [MailMessage] {
        var representatives: [String: MailMessage] = [:]
        for message in candidates {
            let key = conversationKey(for: message)
            if let current = representatives[key] {
                if current.id == selectedMessageID { continue }
                if message.id != selectedMessageID && message.sentAt <= current.sentAt { continue }
            }
            representatives[key] = message
        }
        return candidates.filter { representatives[conversationKey(for: $0)]?.id == $0.id }
    }

    func matchesActiveProviderAccount(_ message: MailMessage) -> Bool {
        if message.mailAccount.isRemote { return message.mailAccount.remote != nil }
        return isPreview && message.mailAccount != .gmail && message.mailAccount != .unassigned
    }

    func sameMailAccount(_ first: MailMessage, _ second: MailMessage) -> Bool {
        guard first.account == second.account else { return false }
        guard let firstEmail = first.providerAccountEmail, let secondEmail = second.providerAccountEmail else { return true }
        return firstEmail.caseInsensitiveCompare(secondEmail) == .orderedSame
    }

    func matchesMailbox(_ message: MailMessage, mailbox: Mailbox, now: Date = .now) -> Bool {
        guard isAccountVisible(message) else { return false }
        let available = !message.isDraft && message.mailbox != .trash && message.mailbox != .outbox
        switch mailbox {
        case .starred: return message.isStarred && message.mailbox != .trash
        case .needsReply: return available && message.workflow.needsReply && message.workflow.screeningState == .accepted && message.workflow.snoozedUntil == nil
        case .snoozed: return available && message.workflow.snoozedUntil != nil
        case .followUps: return available && message.workflow.followUpAt != nil
        case .newSenders: return available && message.workflow.screeningState == .pending
        case .inbox:
            return message.mailbox == .inbox && message.workflow.screeningState == .accepted && message.workflow.snoozedUntil == nil
        default: return message.mailbox == mailbox
        }
    }

    func matchesSavedView(_ message: MailMessage, criteria: SavedInboxCriteria) -> Bool {
        guard isAccountVisible(message) else { return false }
        if let mailbox = criteria.mailbox, !matchesMailbox(message, mailbox: mailbox) { return false }
        if let account = criteria.account, message.account != account { return false }
        if criteria.unreadOnly && !message.isUnread { return false }
        if criteria.attachmentsOnly && message.attachments.isEmpty { return false }
        if criteria.starredOnly && !message.isStarred { return false }
        if !criteria.sender.isEmpty && !message.senderEmail.localizedStandardContains(criteria.sender)
            && !message.sender.localizedStandardContains(criteria.sender) { return false }
        let domain = criteria.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        if !domain.isEmpty && message.senderEmail.lowercased().split(separator: "@").last.map(String.init) != domain { return false }
        return parsedQuery(criteria.query, field: criteria.searchField).matches(message, context: searchContext)
    }

    func selectSavedView(_ view: SavedInboxView) {
        selectedMailbox = .inbox
        selectedAccount = nil
        clearFilters()
        selectedSavedViewID = view.id
        selectedMessageID = filteredMessages.first?.id
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
        for index in updated.indices where updated[index].conversationID == selected.conversationID && sameMailAccount(updated[index], selected) {
            update(&updated[index])
        }
        messages = updated
        reconcileSelection()
    }

    func setNeedsReply(_ needsReply: Bool, for id: UUID) {
        updateConversation(containing: id) { $0.workflow.needsReply = needsReply }
        lastAction = needsReply ? "Added to Needs Reply" : "Marked done"
    }

    func snoozeMessage(_ id: UUID, until date: Date) {
        guard date > .now else { unsnoozeMessage(id); return }
        updateConversation(containing: id) { $0.workflow.snoozedUntil = date }
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
        for index in updated.indices where matchesRule(normalized, message: updated[index]) && !updated[index].isOutgoing && !updated[index].isDeletedOnProvider {
            applyRule(normalized, to: &updated[index])
        }
        messages = updated
        reconcileSelection()
    }

    func deleteSenderRule(_ id: UUID) { senderRules.removeAll { $0.id == id } }

    func acceptSender(of message: MailMessage, route: SenderRoute = .inbox) {
        saveSenderRule(SenderRule(email: message.senderEmail, account: message.account, route: route, providerAccountEmail: message.providerAccountEmail))
        lastAction = "Sender accepted · \(route.title)"
    }

    func blockSender(of message: MailMessage) {
        saveSenderRule(SenderRule(email: message.senderEmail, account: message.account, route: .blocked, providerAccountEmail: message.providerAccountEmail))
        lastAction = "Sender blocked"
    }

    func matchesRule(_ rule: SenderRule, message: MailMessage) -> Bool {
        rule.email.caseInsensitiveCompare(message.senderEmail) == .orderedSame && (rule.account == nil || rule.account == message.account)
            && (rule.providerAccountEmail == nil || rule.providerAccountEmail?.lowercased() == message.providerAccountEmail?.lowercased())
    }

    func permitsIncomingNotification(_ message: MailMessage) -> Bool {
        guard message.isUnread, !message.isOutgoing, !message.isDeletedOnProvider, message.mailbox == .inbox else { return false }
        if let rule = senderRules.first(where: { matchesRule($0, message: message) }) {
            return rule.route == .inbox || rule.route == .needsReply
        }
        return !senderScreeningEnabled
    }

    func applyRule(_ rule: SenderRule, to message: inout MailMessage) {
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
        for message in messages where isAccountVisible(message) && !message.isDraft && message.mailbox != .trash && message.mailbox != .outbox {
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
