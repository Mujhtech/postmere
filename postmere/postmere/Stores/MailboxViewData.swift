import Foundation

nonisolated struct MailboxViewScope: Equatable, Sendable {
    let accounts: Set<String>
    let account: String?
    let mailbox: Mailbox
    let savedViewID: UUID?
    var splitID: UUID?
    let query: String
    let searchScope: MailSearchScope
    let searchField: MailSearchField
    let unreadOnly: Bool
    let attachmentsOnly: Bool
    let rulesRevision: Int
    let localDay = Calendar.current.startOfDay(for: .now)

    var isUnfilteredInbox: Bool {
        mailbox == .inbox && savedViewID == nil && query.isEmpty && !unreadOnly && !attachmentsOnly
    }
}

nonisolated struct MailboxViewKey: Equatable, Sendable {
    let scope: MailboxViewScope
    let messageRevision: Int
    let preferredRepresentative: UUID?
}

nonisolated struct MailboxViewData: Sendable {
    struct Section: Identifiable, Sendable {
        let id: String
        let offset: Int
        let messages: ArraySlice<MailMessage>
    }

    let key: MailboxViewKey
    let messages: [MailMessage]
    let conversationCounts: [UUID: Int]
    let sections: [Section]
    let rowPositions: [UUID: Int]
    let overview: InboxOverview

    init?(key: MailboxViewKey, request: MailSearchRequest, snapshot: [MailMessage], overviewTitle: String?) {
        let messages = request.run(snapshot, interactive: false)
        guard !Task.isCancelled else { return nil }
        // A date section normally occupies a contiguous slice, even in a filtered inbox.
        // Keep the same message storage for both the flat list and its sections.
        var ranges: [String: [Range<Int>]] = [:]
        var dates: [String] = []
        var start = 0
        for index in messages.indices {
            if Task.isCancelled { return nil }
            let date = messages[index].dateLabel
            let end = index + 1
            if end == messages.count || messages[end].dateLabel != date {
                if ranges[date] == nil { dates.append(date) }
                ranges[date, default: []].append(start..<end)
                start = end
            }
        }
        self.key = key
        self.messages = messages
        var sections: [Section] = []
        var positions: [UUID: Int] = [:]
        positions.reserveCapacity(messages.count)
        for date in dates {
            guard let runs = ranges[date], let first = runs.first, !Task.isCancelled else { return nil }
            let rows = runs.count == 1 ? messages[first] : runs.flatMap { messages[$0] }[...]
            sections.append(Section(id: date, offset: positions.count, messages: rows))
            for row in rows { positions[row.id] = positions.count }
        }
        self.sections = sections
        self.rowPositions = positions
        self.conversationCounts = Self.conversationCounts(in: snapshot, for: messages)
        guard !Task.isCancelled else { return nil }
        self.overview = InboxOverview(messages: snapshot, visible: messages, request: request, title: overviewTitle)
    }

    static func conversationCounts(in messages: [MailMessage], for visible: [MailMessage]) -> [UUID: Int] {
        struct Thread: Hashable {
            let conversationID: UUID
            let account: String
            nonisolated init(_ message: MailMessage) {
                conversationID = message.conversationID
                account = message.account
            }
        }
        struct Counts {
            var total = 0
            var withoutIdentity = 0
            var byEmail: [String: Int] = [:]
        }
        guard !visible.isEmpty else { return [:] }
        var counts: [Thread: Counts] = [:]
        for message in messages {
            if Task.isCancelled { return [:] }
            guard !message.isDraft, message.providerDeletedAt == nil, !message.mailbox.isJunkOrTrash else { continue }
            let thread = Thread(message)
            counts[thread, default: Counts()].total += 1
            if let email = message.legacyAccountAddress {
                counts[thread, default: Counts()].byEmail[email, default: 0] += 1
            } else {
                counts[thread, default: Counts()].withoutIdentity += 1
            }
        }
        var result: [UUID: Int] = [:]
        result.reserveCapacity(visible.count)
        for message in visible {
            if Task.isCancelled { return [:] }
            if message.isDraft {
                result[message.id] = 1
                continue
            }
            let thread = counts[Thread(message)] ?? Counts()
            let count = message.legacyAccountAddress.map { thread.withoutIdentity + thread.byEmail[$0, default: 0] } ?? thread.total
            result[message.id] = count + (message.mailbox.isJunkOrTrash && message.providerDeletedAt == nil ? 1 : 0)
        }
        return result
    }
}

extension MailStore {
    var mailboxViewKey: MailboxViewKey {
        let scope = MailboxViewScope(accounts: searchableAccounts, account: selectedAccount, mailbox: selectedMailbox,
                                     savedViewID: selectedSavedViewID, splitID: selectedInboxSplitID, query: searchText,
                                     searchScope: searchScope, searchField: searchField, unreadOnly: unreadOnly,
                                     attachmentsOnly: attachmentsOnly, rulesRevision: mailboxRulesRevision)
        let usesRepresentatives = (selectedSavedView?.criteria.mailbox ?? selectedMailbox).isConversationQueue
            || (selectedMailbox == .inbox && selectedSavedViewID == nil && selectedInboxSplitID != nil)
        var preferred = usesRepresentatives ? selectedMessageID : nil
        if let pending = pendingMailboxSelection, pending.scope == scope, pending.previous == selectedMessageID {
            preferred = nil
        }
        // Selecting a row already chosen by the default grouping does not change the grouping.
        if let id = preferred, let data = loadedMailboxView, data.key.scope == scope,
           data.key.messageRevision == mailboxDataRevision, data.key.preferredRepresentative == nil,
           data.rowPositions[id] != nil { preferred = nil }
        return MailboxViewKey(scope: scope, messageRevision: mailboxDataRevision, preferredRepresentative: preferred)
    }

    /// Keep the painted rows during a refresh within the same scope, including read-state changes.
    /// Account removal and navigation invalidate them immediately.
    var mailboxViewData: MailboxViewData? {
        guard !isSearchActive, let loadedMailboxView, loadedMailboxView.key.scope == mailboxViewKey.scope else { return nil }
        return loadedMailboxView
    }

    /// During a same-account tab switch the native list can keep its row views behind the loading indicator.
    var previousInboxTabForLayout: MailboxViewData? {
        guard !isSearchActive, let loadedMailboxView else { return nil }
        let previous = loadedMailboxView.key.scope
        var target = mailboxViewKey.scope
        guard target.isUnfilteredInbox, previous.splitID != target.splitID else { return nil }
        target.splitID = previous.splitID
        return target == previous ? loadedMailboxView : nil
    }

    @discardableResult
    func startMailboxViewLoad() -> Task<Void, Never>? {
        guard !isSearchActive else {
            mailboxViewTask?.cancel()
            mailboxViewTask = nil
            loadingMailboxKey = nil
            pendingMailboxSelection = nil
            return nil
        }
        let key = mailboxViewKey
        if loadingMailboxKey == key { return mailboxViewTask }
        mailboxViewTask?.cancel()
        mailboxViewTask = nil
        loadingMailboxKey = nil
        if let data = loadedMailboxView, data.key == key {
            finishMailboxSelection(in: data)
            return nil
        }
        let request = searchRequest(splitID: key.scope.splitID, preferredID: key.preferredRepresentative)
        let snapshot = messages
        let title = overviewTitle
        loadingMailboxKey = key
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled,
                  let data = MailboxViewData(key: key, request: request, snapshot: snapshot, overviewTitle: title),
                  !Task.isCancelled else { return }
            await self?.acceptMailboxView(data)
        }
        mailboxViewTask = task
        return task
    }

    func loadMailboxView() async {
        usesMailboxViewData = true
        await startMailboxViewLoad()?.value
    }

    private func acceptMailboxView(_ data: MailboxViewData) {
        guard loadingMailboxKey == data.key else { return }
        loadingMailboxKey = nil
        mailboxViewTask = nil
        guard !isSearchActive, data.key == mailboxViewKey else {
            // A mutation can land while a navigation result is pending and before a view appears.
            if pendingMailboxSelection?.scope == mailboxViewKey.scope { startMailboxViewLoad() }
            return
        }
        loadedMailboxView = data
        if data.key.scope.isUnfilteredInbox, data.key.preferredRepresentative == nil {
            rememberInboxTab(data, generation: inboxTabCountKey)
        }
        finishMailboxSelection(in: data)
    }

    private func finishMailboxSelection(in data: MailboxViewData) {
        if let pending = pendingMailboxSelection {
            pendingMailboxSelection = nil
            if selectedMessageID == pending.previous, selectedMessageIDs.count <= 1, pending.scope == data.key.scope {
                selectedMessageID = data.messages.first?.id
                if pending.markRead { markSelectedRead() }
                return
            }
        }
        if pendingMoveSelection == nil, selectedMessageIDs.count == 1, let id = selectedMessageID,
           data.rowPositions[id] != nil { return }
        reconcileSelection(in: data.messages)
    }

    /// Switching mailboxes, tabs, saved views or accounts lands on the
    /// mailbox overview; the reader opens only when a conversation is chosen.
    func showMailboxOverview() {
        pendingMailboxSelection = nil
        selectedMessageID = nil
        guard usesMailboxViewData || needsBackgroundSearch else { return }
        if let data = preparedInboxTab(in: mailboxViewKey.scope) {
            mailboxViewTask?.cancel()
            mailboxViewTask = nil
            loadingMailboxKey = nil
            loadedMailboxView = data
            return
        }
        startMailboxViewLoad()
    }

    private func preparedInboxTab(in scope: MailboxViewScope) -> MailboxViewData? {
        guard scope.isUnfilteredInbox, preparedInboxKey == inboxTabCountKey else { return nil }
        return preparedInboxTabs.first { $0.key.scope == scope }
    }

    private func rememberInboxTab(_ data: MailboxViewData, generation: InboxTabCountKey) {
        if preparedInboxKey != generation {
            preparedInboxTabs = []
            preparedInboxKey = generation
        }
        guard !preparedInboxTabs.contains(where: { $0.key == data.key }) else { return }
        // Allow a recently opened overflow tab alongside All and the four leading tabs.
        if preparedInboxTabs.count == 6 { preparedInboxTabs.removeFirst() }
        preparedInboxTabs.append(data)
    }

    /// Prepare the leading tabs while reading so a switch publishes the rows and reader in one UI update.
    func prepareInboxTabs() async {
        let key = inboxTabCountKey
        let scope = mailboxViewKey.scope
        guard !isSearchActive, scope.isUnfilteredInbox else { return }
        let snapshot = messages
        let splits = visibleInboxSplits
        let tabs: [(id: UUID?, title: String?)] = [(nil, nil)] + splits.prefix(4).map { ($0.id, $0.name) }
        // Capture every request before suspending. Account, search and filter choices can change during preparation.
        let work = tabs.compactMap { tab -> (MailboxViewKey, MailSearchRequest, String?)? in
            var target = scope
            target.splitID = tab.id
            let targetKey = MailboxViewKey(scope: target, messageRevision: key.messageRevision, preferredRepresentative: nil)
            if preparedInboxKey == key, preparedInboxTabs.contains(where: { $0.key == targetKey }) { return nil }
            if let current = loadedMailboxView, current.key == targetKey {
                rememberInboxTab(current, generation: key)
                return nil
            }
            return (targetKey, searchRequest(splitID: tab.id, preferredID: nil), tab.title)
        }
        for (target, request, title) in work {
            guard !Task.isCancelled else { return }
            let data = await MailboxViewData.prepare(key: target, request: request, snapshot: snapshot, title: title)
            guard let data, !Task.isCancelled, key == inboxTabCountKey else { return }
            rememberInboxTab(data, generation: key)
        }
    }
}

extension MailboxViewData {
    @concurrent static func prepare(key: MailboxViewKey, request: MailSearchRequest,
                                    snapshot: [MailMessage], title: String?) async -> MailboxViewData? {
        MailboxViewData(key: key, request: request, snapshot: snapshot, overviewTitle: title)
    }
}
