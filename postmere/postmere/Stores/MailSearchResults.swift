import Foundation
import Observation

extension MailStore {
    var searchableAccounts: Set<String> {
        var ids = Set(RemoteAccountRegistry.accounts.lazy.map(\.localID).filter { $0.hasPrefix("remote:") })
        if isPreview { ids.formUnion([MailAccount.work.rawValue, MailAccount.personal.rawValue]) }
        return ids
    }
}

nonisolated extension MailMessage {
    var searchConversationKey: String { "\(account)|\(legacyAccountAddress ?? "")|\(conversationID.uuidString)" }

    func belongs(to mailbox: Mailbox) -> Bool {
        let available = !isDraft && !self.mailbox.isJunkOrTrash && self.mailbox != .outbox
        switch mailbox {
        case .starred: return isStarred && !self.mailbox.isJunkOrTrash
        case .needsReply: return available && needsReply && workflow.screeningState == .accepted && workflow.snoozedUntil == nil
        case .snoozed: return available && workflow.snoozedUntil != nil
        case .followUps: return available && workflow.followUpAt != nil
        case .newSenders: return available && workflow.screeningState == .pending
        case .inbox:
            return self.mailbox == .inbox && workflow.screeningState == .accepted && workflow.snoozedUntil == nil
        default: return self.mailbox == mailbox
        }
    }
}

nonisolated struct MailCriteriaMatcher: Sendable {
    let criteria: SavedInboxCriteria
    let query: MailSearchQuery

    func matches(_ message: MailMessage, context: MailSearchContext) -> Bool {
        if let mailbox = criteria.mailbox, !message.belongs(to: mailbox) { return false }
        if let account = criteria.account, message.account != account { return false }
        if criteria.unreadOnly && !message.isUnread { return false }
        if criteria.attachmentsOnly && message.attachments.isEmpty { return false }
        if criteria.starredOnly && !message.isStarred { return false }
        if !criteria.sender.isEmpty && !message.senderEmail.localizedStandardContains(criteria.sender)
            && !message.sender.localizedStandardContains(criteria.sender) { return false }
        let domain = criteria.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        if !domain.isEmpty && message.senderEmail.lowercased().split(separator: "@").last.map(String.init) != domain { return false }
        return query.matches(message, context: context)
    }
}

/// Immutable account and mailbox scope captured when the user edits their search.
nonisolated struct MailSearchRequest: Sendable {
    let accounts: Set<String>
    let account: String?
    let mailbox: Mailbox?
    let saved: MailCriteriaMatcher?
    let split: MailCriteriaMatcher?
    let earlierSplits: [MailCriteriaMatcher]
    let query: MailSearchQuery
    let context: MailSearchContext
    let unreadOnly: Bool
    let attachmentsOnly: Bool
    let selectedID: UUID?

    static func representatives(_ candidates: [MailMessage], preferred: UUID?) -> [MailMessage] {
        var representatives: [String: MailMessage] = [:]
        for message in candidates {
            if Task.isCancelled { return [] }
            let key = message.searchConversationKey
            if let current = representatives[key] {
                if current.id == preferred { continue }
                if message.id != preferred && message.sentAt <= current.sentAt { continue }
            }
            representatives[key] = message
        }
        var result: [MailMessage] = []
        result.reserveCapacity(representatives.count)
        for message in candidates {
            if Task.isCancelled { return [] }
            if representatives[message.searchConversationKey]?.id == message.id { result.append(message) }
        }
        return result
    }

    func visible(_ message: MailMessage) -> Bool {
        accounts.contains(message.account) && (account == nil || account == message.account)
            && (message.providerDeletedAt == nil || message.isDraft || message.mailbox == .outbox)
    }

    func run(_ messages: [MailMessage], interactive: Bool = true, cancellable: Bool = true) -> [MailMessage] {
        var splitKeys = Set<String>()
        if let split {
            var earlierKeys = Set<String>()
            for message in messages {
                if cancellable && Task.isCancelled { return [] }
                guard visible(message), message.belongs(to: .inbox) else { continue }
                if split.matches(message, context: context) { splitKeys.insert(message.searchConversationKey) }
                if earlierSplits.contains(where: { $0.matches(message, context: context) }) { earlierKeys.insert(message.searchConversationKey) }
            }
            splitKeys.subtract(earlierKeys)
        }
        var results: [MailMessage] = []
        for message in messages {
            if cancellable && Task.isCancelled { return [] }
            guard visible(message), !unreadOnly || message.isUnread, !attachmentsOnly || !message.attachments.isEmpty else { continue }
            if let saved {
                guard saved.matches(message, context: context) else { continue }
            } else if let mailbox, !message.belongs(to: mailbox) { continue }
            if split != nil && !splitKeys.contains(message.searchConversationKey) { continue }
            if query.matches(message, context: context) { results.append(message) }
        }
        if split != nil || (saved?.criteria.mailbox ?? mailbox)?.isConversationQueue == true {
            results = Self.representatives(results, preferred: selectedID)
        }
        guard interactive else { return results }
        return results.sorted {
            if $0.sentAt != $1.sentAt { return $0.sentAt > $1.sentAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

extension MailStore {
    func matcher(_ criteria: SavedInboxCriteria) -> MailCriteriaMatcher {
        MailCriteriaMatcher(criteria: criteria, query: parsedQuery(criteria.query, field: criteria.searchField))
    }

    func searchRequest() -> MailSearchRequest {
        searchRequest(splitID: selectedInboxSplitID, preferredID: selectedMessageID)
    }

    func searchRequest(splitID: UUID?, preferredID: UUID?) -> MailSearchRequest {
        let mailbox: Mailbox? = searchesAllMailboxes ? nil : selectedMailbox
        let saved = searchesAllMailboxes ? nil : selectedSavedView.map { matcher($0.criteria) }
        let splits = visibleInboxSplits
        let index = mailbox == .inbox && saved == nil ? splits.firstIndex { $0.id == splitID } : nil
        var earlier: [MailCriteriaMatcher] = []
        if let index, inboxSplitOverlapPolicy == .firstMatch { earlier = splits[..<index].map { matcher($0.criteria) } }
        let context = MailSearchContext(vipContacts: vipContacts, referenceDate: .now, labelIDsByName: labelIDsByName)
        return MailSearchRequest(accounts: searchableAccounts, account: selectedAccount, mailbox: mailbox,
                                 saved: saved, split: index.map { matcher(splits[$0].criteria) }, earlierSplits: earlier,
                                 query: parsedSearchQuery, context: context, unreadOnly: unreadOnly,
                                 attachmentsOnly: attachmentsOnly, selectedID: preferredID)
    }

    var activeSearchResults: [MailMessage] {
        // A registry change can precede its asynchronous refresh callback on sign-out.
        searchResultScope?.accounts == searchableAccounts ? searchResults : []
    }

    func watchSearchAccounts() {
        guard !watchingSearchAccounts else { return }
        watchingSearchAccounts = true
        withObservationTracking {
            _ = RemoteAccountRegistry.shared.values
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.watchingSearchAccounts = false
                if self.isSearchActive {
                    self.watchSearchAccounts()
                    self.refreshSearch()
                }
            }
        }
    }

    func resetSearchResults(keepingRowsIn scope: MailboxViewScope? = nil) {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        if scope == nil || searchResultScope != scope {
            searchResults = []
            searchConversationCounts = [:]
        }
        searchResultScope = scope
        isSearchingMessages = false
    }

    func refreshSearch() {
        guard isSearchActive else { return }
        guard hasSearchCriteria else {
            resetSearchResults()
            reconcileSelection()
            return
        }
        // Keep this query's rows mounted while synchronization refreshes them.
        resetSearchResults(keepingRowsIn: mailboxViewKey.scope)
        let request = searchRequest()
        let snapshot = messages
        if !usesMailboxViewData && !needsBackgroundSearch {
            searchResults = request.run(snapshot)
            searchConversationCounts = MailboxViewData.conversationCounts(in: snapshot, for: searchResults)
            reconcileSelection()
            return
        }
        let generation = searchGeneration
        isSearchingMessages = true
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = request.run(snapshot)
            guard !Task.isCancelled else { return }
            let counts = MailboxViewData.conversationCounts(in: snapshot, for: result)
            guard !Task.isCancelled else { return }
            await self?.finishSearch(result, counts: counts, generation: generation)
        }
    }

    /// Small mailboxes complete inline. Either many rows or one long newsletter can make a body scan expensive.
    var needsBackgroundSearch: Bool {
        if messages.count >= 128 { return true }
        var bytes = 0
        for message in messages {
            for paragraph in message.paragraphs {
                bytes += paragraph.utf8.count
                if bytes >= 384 * 1024 { return true }
            }
        }
        return false
    }

    private func finishSearch(_ result: [MailMessage], counts: [UUID: Int], generation: Int) {
        guard isSearchActive, searchGeneration == generation else { return }
        guard searchResultScope?.accounts == searchableAccounts else { refreshSearch(); return }
        searchConversationCounts = counts
        searchResults = result
        isSearchingMessages = false
        searchTask = nil
        reconcileSelection()
    }

    func refreshSearchRow(_ message: MailMessage) {
        guard isSearchActive else { return }
        if isSearchingMessages { refreshSearch(); return }
        if let index = searchResults.firstIndex(where: { $0.id == message.id }) {
            searchResults[index] = message
        }
    }
}

extension MailStore {
    /// One conversation per row from a mailbox or inbox tab, newest first, for a triage
    /// pass. Independent of what the mail list is showing or filtering; only the chosen
    /// account applies.
    func triageCandidates(mailbox: Mailbox, splitID: UUID? = nil) -> [MailMessage] {
        let splits = visibleInboxSplits
        let index = mailbox == .inbox ? splits.firstIndex { $0.id == splitID } : nil
        var earlier: [MailCriteriaMatcher] = []
        if let index, inboxSplitOverlapPolicy == .firstMatch { earlier = splits[..<index].map { matcher($0.criteria) } }
        let context = MailSearchContext(vipContacts: vipContacts, referenceDate: .now, labelIDsByName: labelIDsByName)
        let request = MailSearchRequest(accounts: searchableAccounts, account: selectedAccount, mailbox: mailbox,
                                        saved: nil, split: index.map { matcher(splits[$0].criteria) }, earlierSplits: earlier,
                                        query: parsedQuery(""), context: context, unreadOnly: false,
                                        attachmentsOnly: false, selectedID: nil)
        let rows = request.run(messages, interactive: true, cancellable: false)
            .filter { !$0.isDraft && $0.mailbox != .outbox }
        return MailSearchRequest.representatives(rows, preferred: nil)
    }
}
