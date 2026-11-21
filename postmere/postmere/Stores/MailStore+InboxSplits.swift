import Foundation

extension MailStore {
    var searchContext: MailSearchContext { MailSearchContext(vipContacts: vipContacts) }
    var parsedSearchQuery: MailSearchQuery { parsedQuery(searchText, field: searchField) }
    var searchTokens: [MailSearchToken] { parsedSearchQuery.tokens }
    var searchIssues: [MailSearchIssue] { parsedSearchQuery.issues }
    var visibleInboxSplits: [InboxSplit] { inboxSplits.filter { !$0.isHidden } }

    func parsedQuery(_ text: String, field: MailSearchField = .all) -> MailSearchQuery {
        let key = "\(field.rawValue)|\(Calendar.current.timeZone.identifier)|\(text)"
        if let cached = searchQueryCache[key] { return cached }
        let query = MailSearchQuery(source: text, defaultField: field)
        if searchQueryCache.count >= 128 { searchQueryCache.removeAll(keepingCapacity: true) }
        searchQueryCache[key] = query
        return query
    }

    func removeSearchToken(_ id: String) { searchText = parsedSearchQuery.removingToken(id: id) }
    func updateSearchToken(_ id: String, with value: String) { searchText = parsedSearchQuery.replacingToken(id: id, with: value) }

    func isVIP(_ message: MailMessage) -> Bool { !searchContext.matchingVIPs(for: message).isEmpty }

    @discardableResult
    func saveVIPContact(_ contact: VIPContact) -> Bool {
        var contact = contact
        contact.value = contact.normalizedValue
        guard contact.isValid else {
            operationError = contact.kind == .person ? "Enter one complete email address, such as person@example.com." : "Enter a domain, such as example.com, without a URL or @ sign."
            return false
        }
        contact.providerAccountEmail = contact.providerAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = vipContacts.firstIndex(where: {
            $0.id == contact.id || ($0.normalizedValue == contact.value && $0.kind == contact.kind
                && $0.account == contact.account && $0.providerAccountEmail == contact.providerAccountEmail)
        }) {
            contact.id = vipContacts[index].id
            vipContacts[index] = contact
        } else { vipContacts.append(contact) }
        operationError = nil
        lastAction = "VIP saved"
        return true
    }

    func deleteVIPContact(_ id: UUID) {
        vipContacts.removeAll { $0.id == id }
        lastAction = "VIP removed"
    }

    @discardableResult
    func saveInboxSplit(_ split: InboxSplit) -> Bool {
        var split = split
        split.name = split.name.trimmingCharacters(in: .whitespacesAndNewlines)
        split.criteria.mailbox = .inbox
        guard !split.name.isEmpty else { operationError = "Give this inbox tab a name."; return false }
        let query = parsedQuery(split.criteria.query, field: split.criteria.searchField)
        guard query.isValid else { operationError = query.issues.first?.message; return false }
        if let index = inboxSplits.firstIndex(where: { $0.id == split.id }) { inboxSplits[index] = split }
        else { inboxSplits.append(split) }
        if split.isHidden && selectedInboxSplitID == split.id { selectedInboxSplitID = nil }
        operationError = nil
        lastAction = "Inbox tab saved"
        return true
    }

    func deleteInboxSplit(_ id: UUID) {
        inboxSplits.removeAll { $0.id == id }
        if selectedInboxSplitID == id { selectedInboxSplitID = nil }
        lastAction = "Inbox tab removed"
    }

    func moveInboxSplit(id: UUID, to destination: Int) {
        guard let source = inboxSplits.firstIndex(where: { $0.id == id }), !inboxSplits.isEmpty else { return }
        let destination = max(0, min(destination, inboxSplits.count - 1))
        guard source != destination else { return }
        var reordered = inboxSplits
        let split = reordered.remove(at: source)
        reordered.insert(split, at: destination)
        inboxSplits = reordered
        lastAction = "Inbox tabs reordered"
    }

    func setInboxSplitHidden(_ id: UUID, hidden: Bool) {
        guard let index = inboxSplits.firstIndex(where: { $0.id == id }) else { return }
        inboxSplits[index].isHidden = hidden
        if hidden && selectedInboxSplitID == id { selectedInboxSplitID = nil }
    }

    func selectInboxSplit(_ id: UUID?) {
        guard id == nil || visibleInboxSplits.contains(where: { $0.id == id }) else { return }
        isSelectingInboxTab = true
        selectedSavedViewID = nil
        selectedMailbox = .inbox
        selectedInboxSplitID = id
        clearFilters()
        isSelectingInboxTab = false
        showMailboxOverview()
    }

    private var splitCandidates: [MailMessage] {
        messages.filter { matchesMailbox($0, mailbox: .inbox) && (selectedAccount == nil || $0.account == selectedAccount) }
    }

    /// Evaluate whole conversations so first-match never places different replies
    /// from the same conversation in competing tabs. Hidden tabs reserve nothing.
    func matchingSplitConversationKeys(_ id: UUID) -> Set<String> {
        guard let target = visibleInboxSplits.firstIndex(where: { $0.id == id }) else { return [] }
        let candidates = splitCandidates
        let targetSplit = visibleInboxSplits[target]
        var keys = Set(candidates.filter { matchesSavedView($0, criteria: targetSplit.criteria) }.map { conversationKey(for: $0) })
        if inboxSplitOverlapPolicy == .firstMatch && target > 0 {
            for earlier in visibleInboxSplits[..<target] {
                let priorKeys = candidates.filter { matchesSavedView($0, criteria: earlier.criteria) }.map { conversationKey(for: $0) }
                keys.subtract(priorKeys)
            }
        }
        return keys
    }

    func splitMessages(_ id: UUID) -> [MailMessage] {
        let keys = matchingSplitConversationKeys(id)
        return deduplicatedConversations(splitCandidates.filter { keys.contains(conversationKey(for: $0)) })
    }

    var inboxTabCounts: InboxTabCounts { tabCountRequest().run(messages) }

    func splitMatchReasons(for message: MailMessage, splitID: UUID) -> [String] {
        guard let split = visibleInboxSplits.first(where: { $0.id == splitID }),
              matchingSplitConversationKeys(splitID).contains(conversationKey(for: message)) else { return [] }
        let matching = splitCandidates.filter {
            conversationKey(for: $0) == conversationKey(for: message) && matchesSavedView($0, criteria: split.criteria)
        }
        var reasons = matching.flatMap { parsedQuery(split.criteria.query, field: split.criteria.searchField).reasons(for: $0, context: searchContext) }
        let criteria = split.criteria
        if let account = criteria.account { reasons.append("Account: \(account)") }
        if criteria.unreadOnly { reasons.append("The conversation has an unread message") }
        if criteria.attachmentsOnly { reasons.append("The conversation has an attachment") }
        if criteria.starredOnly { reasons.append("The conversation has a starred message") }
        if !criteria.sender.isEmpty { reasons.append("Sender matches \(criteria.sender)") }
        if !criteria.domain.isEmpty { reasons.append("Sender domain: \(criteria.domain)") }
        if reasons.isEmpty { reasons = ["Matches all inbox messages"] }
        var seen: Set<String> = []
        reasons = reasons.filter { seen.insert($0).inserted }
        if inboxSplitOverlapPolicy == .firstMatch { reasons.append("\(split.name) is the first matching visible tab") }
        return reasons
    }
}

nonisolated struct InboxTabCountKey: Equatable {
    let accounts: Set<String>
    let account: String?
    let rulesRevision: Int
    let messageRevision: Int
    let localDay = Calendar.current.startOfDay(for: .now)
}

nonisolated struct InboxTabCounts: Sendable {
    var all = 0
    var splits: [UUID: Int] = [:]
}

private nonisolated struct InboxTabCountRequest: Sendable {
    let scope: MailSearchRequest
    let splits: [(id: UUID, matcher: MailCriteriaMatcher)]
    let firstMatch: Bool

    func run(_ messages: [MailMessage]) -> InboxTabCounts {
        var threads: [String: [MailMessage]] = [:]
        for message in messages {
            if Task.isCancelled { return InboxTabCounts() }
            if scope.visible(message) && message.belongs(to: .inbox) {
                threads[message.searchConversationKey, default: []].append(message)
            }
        }
        var counts = InboxTabCounts()
        for thread in threads.values {
            if Task.isCancelled { return InboxTabCounts() }
            guard thread.contains(where: \.isUnread) else { continue }
            counts.all += 1
            for split in splits where thread.contains(where: { split.matcher.matches($0, context: scope.context) }) {
                counts.splits[split.id, default: 0] += 1
                if firstMatch { break }
            }
        }
        return counts
    }
}

extension MailStore {
    var inboxTabCountKey: InboxTabCountKey {
        InboxTabCountKey(accounts: searchableAccounts, account: selectedAccount, rulesRevision: mailboxRulesRevision,
                         messageRevision: mailboxDataRevision)
    }

    private func tabCountRequest() -> InboxTabCountRequest {
        InboxTabCountRequest(scope: searchRequest(),
                             splits: visibleInboxSplits.map { ($0.id, matcher($0.criteria)) },
                             firstMatch: inboxSplitOverlapPolicy == .firstMatch)
    }

    func loadInboxTabCounts() async -> InboxTabCounts {
        let request = tabCountRequest()
        let snapshot = messages
        let task = Task.detached(priority: .utility) { request.run(snapshot) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
