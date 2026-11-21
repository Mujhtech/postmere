import Foundation
import Observation

/// Durable mailbox state. Explicit message fixtures keep persistence disabled for previews and tests.
@MainActor
@Observable
final class MailStore {
    var messages: [MailMessage] {
        didSet {
            // Stored bodies change neither rows nor grouping, so filling them in
            // must not invalidate the mailbox list being built.
            guard !updatingSenderArtwork, !applyingStoredBodies else { return }
            mailboxDataRevision &+= 1
            guard !updatingReaderMessage else { return }
            schedulePersistence()
            syncProviderChanges(from: oldValue)
            if isSearchActive { refreshSearch() }
        }
    }
    private(set) var mailboxDataRevision = 0
    var spamCheckResults: [String: StoredSpamCheck] = [:]
    @ObservationIgnored var replyIndexVersion = MailStateSnapshot.currentReplyIndexVersion
    @ObservationIgnored var workflowDateScan: (revision: Int, visibleAccounts: Set<String>, nextWake: Date?)?
    var mailboxRulesRevision = 0
    var loadedMailboxView: MailboxViewData?
    @ObservationIgnored var preparedInboxTabs: [MailboxViewData] = []
    @ObservationIgnored var preparedInboxKey: InboxTabCountKey?
    @ObservationIgnored var isSelectingInboxTab = false
    @ObservationIgnored var usesMailboxViewData = false
    @ObservationIgnored var mailboxViewTask: Task<Void, Never>?
    @ObservationIgnored var loadingMailboxKey: MailboxViewKey?
    @ObservationIgnored var pendingMailboxSelection: (scope: MailboxViewScope, previous: UUID?, markRead: Bool)?
    var selectedMailbox: Mailbox = .inbox { didSet { if isSearchActive && oldValue != selectedMailbox { refreshSearch() } } }
    var selectedAccount: String? { didSet { if isSearchActive && oldValue != selectedAccount { refreshSearch() } } }
    var selectedMessageID: UUID? {
        didSet {
            if !isUpdatingSelection { selectedMessageIDs = selectedMessageID.map { [$0] } ?? [] }
            if bodySource != nil, let selectedMessageID, selectedMessageID != oldValue { loadBodiesNow(forConversationOf: selectedMessageID) }
        }
    }
    var selectedMessageIDs: Set<UUID> = [] {
        didSet {
            if oldValue.isEmpty != selectedMessageIDs.isEmpty { hasMessageSelection = !selectedMessageIDs.isEmpty }
        }
    }
    private(set) var hasMessageSelection = false
    @ObservationIgnored var isUpdatingSelection = false
    private var searchOrigin: SearchOrigin?
    var isSearchActive: Bool { searchOrigin != nil }
    var isSearchingMessages = false
    var searchResults: [MailMessage] = []
    var searchConversationCounts: [UUID: Int] = [:]
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var searchGeneration = 0
    var searchResultScope: MailboxViewScope?
    @ObservationIgnored var watchingSearchAccounts = false
    /// Each account's Gmail labels or Outlook categories, keyed by account.
    var labelCatalogs: [String: [ProviderLabel]] = [:] {
        didSet {
            var index: [String: Set<String>] = [:]
            for label in labelCatalogs.values.joined() { index[label.name.lowercased(), default: []].insert(label.id) }
            labelIDsByName = index
            if isSearchActive && searchText.hasPrefix("label:") { refreshSearch() }
        }
    }
    @ObservationIgnored private(set) var labelIDsByName: [String: Set<String>] = [:]
    var searchText = "" {
        didSet { if searchText != oldValue { searchFiltersChanged() } }
    }
    var unreadOnly = false {
        didSet { if unreadOnly != oldValue { searchFiltersChanged() } }
    }
    var attachmentsOnly = false {
        didSet { if attachmentsOnly != oldValue { searchFiltersChanged() } }
    }
    var searchScope: MailSearchScope = .currentMailbox {
        didSet { if searchScope != oldValue { searchFiltersChanged() } }
    }
    var searchField: MailSearchField = .all {
        didSet { if searchField != oldValue { searchFiltersChanged() } }
    }
    var isComposing = false { didSet { schedulePersistence() } }
    var draftAccount: MailAccount = .unassigned {
        didSet {
            if oldValue != draftAccount {
                draftProviderAccountEmail = draftAccount.isLive ? draftAccount.email : nil
                if isComposing {
                    draftProviderThreadID = nil
                    draftInReplyTo = nil
                    draftReferences = []
                    draftConversationID = UUID()
                }
            }
            draftChanged()
        }
    }
    var draftTo = "" { didSet { draftChanged() } }
    var draftCc = "" { didSet { draftChanged() } }
    var draftBcc = "" { didSet { draftChanged() } }
    var draftSubject = "" { didSet { draftChanged() } }
    var draftBody = "" { didSet { draftChanged() } }
    var draftBodyRTF: Data? { didSet { draftChanged() } }
    var draftAttachments: [MailAttachment] = [] { didSet { draftChanged() } }
    var composeTitle = "New message"
    var lastAction: String? { didSet { actionRevision += 1; lastActionDetail = nil } }
    /// The subject of the single message an action moved, for its confirmation.
    var lastActionDetail: String?
    private(set) var actionRevision = 0
    private var undoRevision: Int?

    var lastActionOffersUndo: Bool { undoRevision == actionRevision && canUndoMove }

    func announceMove(_ message: String) {
        lastAction = message
        undoRevision = actionRevision
    }
    var editingDraftID: UUID?
    var draftConversationID = UUID()
    var initialDraft = DraftSnapshot()
    private var lastMove: MoveSnapshot?
    /// Set when the open message leaves the reader by a move, or comes back by
    /// Undo, so the reader can animate that change rather than swap instantly.
    var departure: MailDeparture?
    var batchMoveUndo: (messages: [MailMessage], selection: Set<UUID>, lead: UUID?, scope: MailboxViewScope)?
    @ObservationIgnored var pendingMoveSelection: (lead: UUID, selection: Set<UUID>, scope: MailboxViewScope)?
    var savedViews: [SavedInboxView] = [] { didSet { mailboxRulesRevision &+= 1; schedulePersistence(); if isSearchActive { refreshSearch() } } }
    var inboxSplits: [InboxSplit] = InboxSplit.defaults { didSet { mailboxRulesRevision &+= 1; schedulePersistence(); searchFiltersChanged() } }
    var selectedInboxSplitID: UUID? {
        didSet {
            guard oldValue != selectedInboxSplitID else { return }
            schedulePersistence()
            searchFiltersChanged()
        }
    }
    var inboxSplitOverlapPolicy: InboxSplitOverlapPolicy = .firstMatch { didSet { mailboxRulesRevision &+= 1; schedulePersistence(); searchFiltersChanged() } }
    var vipContacts: [VIPContact] = [] { didSet { mailboxRulesRevision &+= 1; schedulePersistence(); searchFiltersChanged() } }
    var snippets: [MailSnippet] = [] { didSet { schedulePersistence() } }
    var senderRules: [SenderRule] = [] { didSet { schedulePersistence(); onNotificationPolicyChanged?() } }
    var outgoingQueue: [OutgoingMailItem] = [] { didSet { persistState() } }
    var senderScreeningEnabled = false { didSet { schedulePersistence(); onNotificationPolicyChanged?() } }
    var selectedSavedViewID: UUID? { didSet { if isSearchActive && oldValue != selectedSavedViewID { refreshSearch() } } }
    var persistenceError: String?
    var backendSyncCursors: [String: String] = [:]
    var backendNotificationCutoffs: [String: Date] = [:]
    var operationError: String?
    var recoveredDraft: ActiveMailDraft?
    var draftSendAt: Date? { didSet { draftChanged() } }
    var draftFollowUpAt: Date? { didSet { draftChanged() } }
    var draftFollowUpOnlyIfNoReply = true { didSet { draftChanged() } }
    var draftInReplyTo: String?
    var draftReferences: [String] = []
    var draftProviderThreadID: String?
    var draftProviderAccountEmail: String?
    var draftTrackOpens = false { didSet { draftChanged() } }
    var draftTrackLinks = false { didSet { draftChanged() } }
    @ObservationIgnored var onCancelRemoteSend: ((UUID) -> Void)?
    @ObservationIgnored var onRetryRemoteSend: ((UUID) -> Void)?
    @ObservationIgnored var remoteMutation: (@MainActor (MailMessage, MailMessage) async throws -> Void)?
    @ObservationIgnored var onSnoozeDue: (@MainActor (MailMessage, Date) -> Void)?
    @ObservationIgnored var onNotificationPolicyChanged: (() -> Void)?
    @ObservationIgnored var providerOverrides: [UUID: ProviderMessageOverride] = [:]
    @ObservationIgnored var pendingMergeReaders: [UUID: (ReaderMailChange) -> Void] = [:]
    @ObservationIgnored var activeProviderPages: [ProviderPageRead] = []
    @ObservationIgnored var suppressRemoteMutations = false
    @ObservationIgnored var remoteMutationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var persistence: MailPersistence?
    private static let persistenceQueue = DispatchQueue(label: "postmere.mail.persistence", qos: .utility)
    var saveQueue: DispatchQueue { Self.persistenceQueue }
    @ObservationIgnored var pendingSave: DispatchWorkItem?
    @ObservationIgnored var saveRevision = 0
    @ObservationIgnored var lastQueuedFingerprint: PersistenceFingerprint?
    @ObservationIgnored private var updatingReaderMessage = false
    @ObservationIgnored var applyingStoredBodies = false
    @ObservationIgnored var bodyFillTask: Task<Void, Never>?
    @ObservationIgnored var preparesListWhileOpening = false
    @ObservationIgnored var bodySource: MailPersistence?
    @ObservationIgnored private var updatingSenderArtwork = false
    private var recentSenderMarks: [UUID: MailVerifiedSenderMark] = [:]
    @ObservationIgnored var searchQueryCache: [String: MailSearchQuery] = [:]
    var isOpeningMailbox = false
    @ObservationIgnored var openingTask: Task<Void, Never>?
    @ObservationIgnored var persistenceReady = false
    @ObservationIgnored var persistenceBlocked = false
    @ObservationIgnored var persistenceSuspended = 0
    /// Explicitly injected sample messages are for previews and offline fixtures only.
    let isPreview: Bool
    @ObservationIgnored var testAttachmentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PostmereFixture-\(UUID().uuidString)", isDirectory: true)

    struct DraftSnapshot: Equatable {
        var account: MailAccount = .unassigned
        var recipient = ""
        var cc = ""
        var bcc = ""
        var subject = ""
        var body = ""
        var bodyRTF: Data?
        var attachments: [MailAttachment] = []
        var sendAt: Date?
        var followUpAt: Date?
        var followUpOnlyIfNoReply = true
        var trackOpens = false
        var trackLinks = false
    }

    private struct MoveSnapshot {
        let original: MailMessage
        let selectedMailbox: Mailbox
        let selectedAccount: String?
        let selectedMessageID: UUID?
        let searchText: String
        let unreadOnly: Bool
        let attachmentsOnly: Bool
        let searchScope: MailSearchScope
        let searchField: MailSearchField
        let searchOrigin: SearchOrigin?
        let savedViewID: UUID?
        let inboxSplitID: UUID?
    }

    /// Browsing filters and the primary row are restored when toolbar search closes.
    private struct SearchOrigin {
        let selectedID: UUID?
        let selection: Set<UUID>
        let text: String
        let scope: MailSearchScope
        let field: MailSearchField
        let unreadOnly: Bool
        let attachmentsOnly: Bool
    }

    init(messages: [MailMessage]? = nil, persistenceURL: URL? = nil, openInBackground: Bool = false) {
        self.isPreview = messages != nil
        var initial = messages ?? []
        MailReplyQueue.index(&initial)
        self.messages = initial
        persistence = persistenceURL.map(MailPersistence.init(fileURL:))
            ?? (messages == nil ? MailPersistence(fileURL: MailPersistence.defaultURL) : nil)
        if openInBackground, let persistence {
            beginOpeningMailbox(persistence)
            return
        }
        loadPersistentState()
        showMailboxOverview()
        persistenceReady = true
        if !persistenceBlocked { persistState() }
    }

    var filteredMessages: [MailMessage] {
        if isSearchActive { return activeSearchResults }
        if let loadedMailboxView, loadedMailboxView.key == mailboxViewKey { return loadedMailboxView.messages }
        return searchRequest().run(messages, interactive: false, cancellable: false)
    }

    var hasSearchCriteria: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || unreadOnly || attachmentsOnly
    }

    var searchesAllMailboxes: Bool {
        searchScope == .allMailboxes && (isSearchActive || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Shows every downloaded message with this label, as a search the user can refine.
    func showLabel(_ name: String) {
        if !isSearchActive { beginSearch() }
        searchScope = .allMailboxes
        searchText = MailSearchQuery.labelCondition(name)
    }

    /// The label whose messages are showing, when the search is exactly one label.
    var shownLabelName: String? {
        guard isSearchActive else { return nil }
        let names = labelCatalogs.values.joined().map(\.name)
        return names.first { MailSearchQuery.labelCondition($0) == searchText }
    }

    func beginSearch() {
        guard !isSearchActive else { return }
        mailboxViewTask?.cancel()
        mailboxViewTask = nil
        loadingMailboxKey = nil
        pendingMailboxSelection = nil
        let origin = SearchOrigin(selectedID: selectedMessageID, selection: selectedMessageIDs,
                                    text: searchText, scope: searchScope, field: searchField,
                                    unreadOnly: unreadOnly, attachmentsOnly: attachmentsOnly)
        selectedMessageID = nil
        searchText = ""
        searchScope = .allMailboxes
        searchField = .all
        unreadOnly = false
        attachmentsOnly = false
        searchOrigin = origin
        watchSearchAccounts()
    }

    private func searchFiltersChanged() {
        guard !isSelectingInboxTab else { return }
        if isSearchActive { refreshSearch() } else { reconcileSelection() }
    }

    func updateSearchText(_ text: String) {
        if !isSearchActive {
            guard !text.isEmpty else { return }
            beginSearch()
        }
        if searchText != text { searchText = text }
    }

    func endSearch() {
        guard let origin = searchOrigin else { return }
        resetSearchResults()
        selectedMessageID = nil
        searchOrigin = nil
        searchText = origin.text
        searchScope = origin.scope
        searchField = origin.field
        unreadOnly = origin.unreadOnly
        attachmentsOnly = origin.attachmentsOnly
        selectedMessageID = origin.selectedID
        selectedMessageIDs = origin.selection
        reconcileSelection()
    }

    @ObservationIgnored private var lastSelectedIndex: Int?
    @ObservationIgnored private var lastReaderThread: (id: UUID, revision: Int, messages: [MailMessage])?

    private var selectedMessageIndex: Int? {
        guard let selectedMessageID else { return nil }
        let snapshot = messages
        if let index = lastSelectedIndex, snapshot.indices.contains(index), snapshot[index].id == selectedMessageID {
            return index
        }
        let index = snapshot.firstIndex { $0.id == selectedMessageID }
        lastSelectedIndex = index
        return index
    }

    var selectedMessage: MailMessage? {
        guard let index = selectedMessageIndex else { return nil }
        let message = messages[index]
        return isAccountVisible(message) ? message : nil
    }

    var selectedConversation: [MailMessage] {
        guard let message = selectedMessage else { return [] }
        if message.isDraft || message.mailbox == .outbox { return [message] }
        let revision = mailboxDataRevision
        if let cached = lastReaderThread, cached.id == message.id, cached.revision == revision {
            return cached.messages
        }
        let thread: [MailMessage]
        if let view = loadedMailboxView, view.key.messageRevision == revision,
           view.key.scope.accounts.contains(message.account),
           view.key.scope.account == nil || view.key.scope.account == message.account,
           !message.isDeletedOnProvider, view.conversationCounts[message.id] == 1 {
            // Counts include every mailbox in the thread, including legacy unscoped addresses.
            thread = [message]
        } else {
            thread = conversationMessages(for: message)
        }
        lastReaderThread = (message.id, revision, thread)
        return thread
    }

    /// Conversation context is independent of mailbox/search filters; actions still target one message.
    func conversationMessages(for message: MailMessage) -> [MailMessage] {
        messages.filter {
            $0.conversationID == message.conversationID && sameMailAccount($0, message)
                && !$0.isDraft && !$0.isDeletedOnProvider && (!$0.mailbox.isJunkOrTrash || $0.id == message.id)
        }
        .sorted {
            if $0.sentAt != $1.sentAt { return $0.sentAt < $1.sentAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func conversationCount(for message: MailMessage) -> Int {
        conversationMessages(for: message).count
    }

    // Build thread counts once for the list. Older cached entries may lack a provider
    // email, in which case sameMailAccount matches any identity on the local account.
    func conversationCounts(for visible: [MailMessage]) -> [UUID: Int] {
        MailboxViewData.conversationCounts(in: messages, for: visible)
    }

    var unreadCount: Int {
        messages.filter { matchesMailbox($0, mailbox: .inbox) && $0.isUnread }.count
    }

    var canSendDraft: Bool {
        draftValidationMessage == nil
    }

    var draftValidationMessage: String? {
        guard draftAccount.isRemote else {
            return "Choose an email account connected to your workspace before sending."
        }
        guard draftAccount.isConnected else { return "Reconnect this account in Settings → Accounts before sending." }
        if let original = draftProviderAccountEmail, !original.isEmpty,
           original.caseInsensitiveCompare(draftAccount.email) != .orderedSame {
            return "This draft belongs to \(original). Select its connected workspace account before sending."
        }
        for (label, input) in [("To", draftTo), ("Cc", draftCc), ("Bcc", draftBcc)] {
            if let invalid = MailAddressList(input).invalid.first {
                return "Check the \(label) address: \(invalid)"
            }
        }
        let recipients = MailAddressList(draftTo).addresses + MailAddressList(draftCc).addresses
            + MailAddressList(draftBcc).addresses
        if recipients.isEmpty { return "Add at least one recipient in To, Cc, or Bcc." }
        if draftSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty {
            return "Add a subject, a message, or an attachment."
        }
        return nil
    }

    var isEditingDraft: Bool { editingDraftID != nil }
    var hasUnsavedDraftChanges: Bool { currentDraft != initialDraft }
    var canUndoMove: Bool { lastMove != nil || batchMoveUndo != nil }

    var currentDraft: DraftSnapshot {
        DraftSnapshot(account: draftAccount, recipient: draftTo, cc: draftCc, bcc: draftBcc,
                      subject: draftSubject, body: draftBody, bodyRTF: draftBodyRTF, attachments: draftAttachments,
                      sendAt: draftSendAt, followUpAt: draftFollowUpAt, followUpOnlyIfNoReply: draftFollowUpOnlyIfNoReply,
                      trackOpens: draftTrackOpens, trackLinks: draftTrackLinks)
    }

    func count(for mailbox: Mailbox) -> Int {
        let matching = messages.filter { matchesMailbox($0, mailbox: mailbox) && (mailbox != .inbox || $0.isUnread) }
        return mailbox.isConversationQueue ? deduplicatedConversations(matching).count : matching.count
    }

    func select(_ message: MailMessage) {
        pendingMailboxSelection = nil
        selectedMessageID = message.id
        markSelectedRead()
    }

    func markSelectedRead() {
        // Keep the unread results stable until the user leaves this filter.
        guard !unreadOnly, let selectedMessageID, let index = selectedMessageIndex, messages[index].isUnread else { return }
        let previous = messages[index]
        if isSearchActive {
            var read = previous
            read.isUnread = false
            let query = parsedSearchQuery
            if query.dependsOnReadState && !query.matches(read, context: searchContext) { return }
            if !searchesAllMailboxes {
                if let saved = selectedSavedView {
                    if saved.criteria.unreadOnly { return }
                    let query = parsedQuery(saved.criteria.query, field: saved.criteria.searchField)
                    if query.dependsOnReadState && !query.matches(read, context: searchContext) { return }
                } else if selectedMailbox == .inbox, let id = selectedInboxSplitID,
                          let index = visibleInboxSplits.firstIndex(where: { $0.id == id }) {
                    let relevant = inboxSplitOverlapPolicy == .firstMatch ? 0...index : index...index
                    if visibleInboxSplits[relevant].contains(where: { split in
                        split.criteria.unreadOnly || parsedQuery(split.criteria.query, field: split.criteria.searchField).dependsOnReadState
                    }) { return }
                }
            }
        }
        updatingReaderMessage = true
        messages[index].isUnread = false
        updatingReaderMessage = false
        for record in pendingMergeReaders.values { record(.read(selectedMessageID)) }
        refreshSearchRow(messages[index])
        schedulePersistence()
        syncProviderChange(from: previous, to: messages[index])
    }

    /// Rows in prepared tabs share immutable snapshots. Overlay late artwork without regrouping them.
    func displayedSenderMark(for message: MailMessage) -> MailVerifiedSenderMark? {
        if let mark = message.currentSenderMark { return mark }
        guard let mark = recentSenderMarks[message.id], mark.matches(message) else { return nil }
        return mark
    }

    func cacheSenderMark(_ mark: MailVerifiedSenderMark, localID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == localID }),
              mark.matches(messages[index]), messages[index].currentSenderMark != mark else { return }
        updatingSenderArtwork = true
        messages[index].verifiedSenderMark = mark
        updatingSenderArtwork = false
        if let position = lastReaderThread?.messages.firstIndex(where: { $0.id == localID }) {
            lastReaderThread?.messages[position].verifiedSenderMark = mark
        }
        if recentSenderMarks.count.isMultiple(of: 64) {
            recentSenderMarks = recentSenderMarks.filter { $0.value.expiresAt > .now }
        }
        recentSenderMarks[localID] = mark
        for record in pendingMergeReaders.values { record(.senderMark(localID, mark)) }
        schedulePersistence()
    }

    func cacheEnvelope(_ details: MailEnvelopeDetails, messageID: UUID, account: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID && $0.account == account }),
              messages[index].envelopeDetails == nil else { return }
        updatingReaderMessage = true
        messages[index].envelopeDetails = details
        updatingReaderMessage = false
        for record in pendingMergeReaders.values { record(.envelope(messageID, details)) }
        refreshSearchRow(messages[index])
        schedulePersistence()
    }

    func selectAdjacent(_ offset: Int) {
        guard let visible = navigableMessages, !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedMessageID } ?? -1
        select(visible[max(0, min(index + offset, visible.count - 1))])
    }

    func selectMailbox(_ mailbox: Mailbox) {
        selectedSavedViewID = nil
        selectedMailbox = mailbox
        selectedAccount = nil
        clearFilters()
        showMailboxOverview()
    }

    func selectAccount(_ account: String?) {
        selectedSavedViewID = nil
        selectedMailbox = .inbox
        selectedAccount = account
        clearFilters()
        showMailboxOverview()
    }

    func clearFilters() {
        if isSearchActive { resetSearchResults() }
        searchOrigin = nil
        searchText = ""
        unreadOnly = false
        attachmentsOnly = false
        searchScope = .currentMailbox
        searchField = .all
    }

    func archiveSelected() {
        moveSelected(to: .archive)
    }

    func deleteSelected() {
        moveSelected(to: .trash)
    }

    func undoLastMove() {
        departure = MailDeparture(messageID: selectedMessageID, destination: nil, subject: nil)
        pendingMoveSelection = nil
        if undoBatchMove() { lastMove = nil; return }
        guard let lastMove,
              let index = messages.firstIndex(where: { $0.id == lastMove.original.id }) else { return }
        var restored = messages[index]
        restored.undoMove(to: lastMove.original)
        var updated = messages
        updated[index] = restored
        MailReplyQueue.reconcile(&updated, conversations: [restored.conversationID])
        messages = updated
        resetSearchResults()
        searchOrigin = nil
        selectedMailbox = lastMove.selectedMailbox
        selectedAccount = lastMove.selectedAccount
        selectedSavedViewID = savedViews.first { $0.id == lastMove.savedViewID }?.id
        let splitID = visibleInboxSplits.first { $0.id == lastMove.inboxSplitID }?.id
        if selectedInboxSplitID != splitID { selectedInboxSplitID = splitID }
        searchText = lastMove.searchText
        unreadOnly = lastMove.unreadOnly
        attachmentsOnly = lastMove.attachmentsOnly
        searchScope = lastMove.searchScope
        searchField = lastMove.searchField
        selectedMessageID = lastMove.selectedMessageID
        searchOrigin = lastMove.searchOrigin
        if isSearchActive { watchSearchAccounts() }
        searchFiltersChanged()
        self.lastMove = nil
        lastAction = "Move undone"
    }

    func toggleStar(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        lastMove = nil
        batchMoveUndo = nil
        messages[index].isStarred.toggle()
        lastAction = messages[index].isStarred ? "Added to Starred" : "Removed from Starred"
        reconcileSelection()
    }

    func toggleRead(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        lastMove = nil
        batchMoveUndo = nil
        messages[index].isUnread.toggle()
        lastAction = messages[index].isUnread ? "Marked as unread" : "Marked as read"
        reconcileSelection()
    }

    func beginCompose(replyTo message: MailMessage? = nil, account: MailAccount? = nil) {
        guard !isComposing, message?.isDraft != true else { return }
        if draftRecoveryAvailable { recoverDraft(); return }
        clearDraft()
        if let message {
            draftInReplyTo = message.rfcMessageID
            draftReferences = message.references + [message.rfcMessageID].compactMap { $0 }
            draftProviderThreadID = message.providerThreadID
            draftConversationID = message.conversationID
            draftAccount = message.mailAccount
            draftProviderAccountEmail = message.providerAccountEmail
            draftTo = replyRecipients(for: message, includeAll: false).to.joined(separator: ", ")
            draftSubject = prefixedSubject(message.subject, prefix: "Re:")
            draftBody = initialBody(quoting: message, forwarded: false)
            composeTitle = "Reply"
        } else {
            draftAccount = account ?? selectedAccount.flatMap(MailAccount.init(rawValue:)) ?? defaultSendingAccount
            draftBody = initialBody()
            composeTitle = "New message"
        }
        initialDraft = currentDraft
        isComposing = true
    }

    /// A URL may supply draft content. The sending identity comes from the active workspace.
    func beginCompose(from link: MailLinkDraft, verifiedScope: String?) -> Bool {
        guard let verifiedScope, !isComposing, !draftRecoveryAvailable, !isOpeningMailbox else { return false }
        let accounts = MailAccount.sendingAccounts.filter { $0.remote?.scope == verifiedScope }
        guard let account = accounts.first(where: { $0.rawValue == selectedAccount })
            ?? accounts.first(where: { $0 == defaultSendingAccount }) ?? accounts.first else { return false }
        persistenceSuspended += 1
        beginCompose(account: account)
        draftTo = link.to
        draftCc = link.cc
        draftBcc = link.bcc
        draftSubject = link.subject
        if let body = link.body, !body.isEmpty {
            let content = MailSignatureBody(text: draftBody, rtfData: draftBodyRTF).prepending(body)
            draftBody = content.text
            draftBodyRTF = content.rtfData
        }
        persistenceSuspended -= 1
        schedulePersistence()
        return true
    }

    func beginReplyAll(_ message: MailMessage) {
        guard !isComposing, !message.isDraft else { return }
        if draftRecoveryAvailable { recoverDraft(); return }
        clearDraft()
        draftInReplyTo = message.rfcMessageID
        draftReferences = message.references + [message.rfcMessageID].compactMap { $0 }
        draftProviderThreadID = message.providerThreadID
        draftConversationID = message.conversationID
        draftAccount = message.mailAccount
        draftProviderAccountEmail = message.providerAccountEmail
        let recipients = replyRecipients(for: message, includeAll: true)
        draftTo = recipients.to.joined(separator: ", ")
        draftCc = recipients.cc.joined(separator: ", ")
        draftSubject = prefixedSubject(message.subject, prefix: "Re:")
        draftBody = initialBody(quoting: message, forwarded: false)
        composeTitle = "Reply all"
        initialDraft = currentDraft
        isComposing = true
    }

    func hasReplyAllRecipients(for message: MailMessage) -> Bool {
        let reply = replyRecipients(for: message, includeAll: false)
        let all = replyRecipients(for: message, includeAll: true)
        return all.to.count + all.cc.count > reply.to.count
    }

    func beginForward(_ message: MailMessage) {
        guard !isComposing, !message.isDraft else { return }
        if draftRecoveryAvailable { recoverDraft(); return }
        clearDraft()
        draftAccount = message.mailAccount
        draftProviderAccountEmail = message.providerAccountEmail
        draftSubject = prefixedSubject(message.subject, prefix: "Fwd:")
        draftBody = initialBody(quoting: message, forwarded: true)
        draftAttachments = message.attachments
        composeTitle = "Forward"
        initialDraft = currentDraft
        isComposing = true
    }

    func beginEditingDraft(_ message: MailMessage) {
        guard !isComposing, message.mailbox == .drafts else { return }
        if draftRecoveryAvailable { recoverDraft(); return }
        clearDraft()
        draftInReplyTo = message.inReplyTo
        draftReferences = message.references
        draftProviderThreadID = message.providerThreadID
        editingDraftID = message.id
        draftConversationID = message.conversationID
        draftAccount = message.mailAccount
        draftProviderAccountEmail = message.providerAccountEmail
        draftTo = message.toRecipients.joined(separator: ", ")
        draftCc = message.ccRecipients.joined(separator: ", ")
        draftBcc = message.bccRecipients.joined(separator: ", ")
        draftSubject = message.subject
        draftBody = message.paragraphs.joined(separator: "\n\n")
        draftBodyRTF = message.bodyRTF
        draftTrackOpens = message.trackOpens ?? false
        draftTrackLinks = message.trackLinks ?? false
        draftAttachments = message.attachments
        draftSendAt = message.workflow.scheduledSendAt
        draftFollowUpAt = message.workflow.followUpAt
        draftFollowUpOnlyIfNoReply = message.workflow.followUpOnlyIfNoReply
        composeTitle = "Draft message"
        initialDraft = currentDraft
        isComposing = true
    }

    func discardDraftChanges() {
        isComposing = false
        clearDraft()
    }

    func saveDraft() {
        guard isEditingDraft || !draftTo.isEmpty || !draftCc.isEmpty || !draftBcc.isEmpty
            || !draftSubject.isEmpty || !draftBody.isEmpty || !draftAttachments.isEmpty else {
            isComposing = false
            clearDraft()
            return
        }
        let draft = composedMessage(in: .drafts)
        let oldMessages = messages
        let oldComposing = isComposing
        persistenceSuspended += 1
        lastMove = nil
        if let editingDraftID, let index = messages.firstIndex(where: { $0.id == editingDraftID }) {
            messages[index] = draft
        } else {
            messages.insert(draft, at: 0)
        }
        isComposing = false
        persistenceSuspended -= 1
        guard persistState() else {
            persistenceSuspended += 1
            messages = oldMessages
            isComposing = oldComposing
            persistenceSuspended -= 1
            return
        }
        reconcileSelection()
        clearDraft()
        lastAction = "Draft saved"
    }

    /// Persists the outgoing message before closing the composer. Delivery is processed after the undo window.
    func sendDraft() {
        queueCurrentDraft()
    }

    @discardableResult
    func moveSelected(to mailbox: Mailbox) -> Bool {
        if selectedMessageIDs.count > 1 { return moveMessages(selectedMessageIDs, to: mailbox) }
        guard let selectedMessageID else { return false }
        return moveMessage(selectedMessageID, to: mailbox)
    }

    func canMoveSelected(to mailbox: Mailbox) -> Bool {
        if selectedMessageIDs.count > 1 { return selectedMessages.contains { canMoveMessage($0, to: mailbox) } }
        return selectedMessage.map { canMoveMessage($0, to: mailbox) } ?? false
    }

    func canMoveMessage(_ message: MailMessage, to mailbox: Mailbox) -> Bool {
        ([.inbox, .archive, .trash].contains(mailbox) || (mailbox == .junk && !message.isFromAccountOwner))
            && message.mailbox != mailbox
            && message.mailbox != .outbox && (!message.isDraft || mailbox == .trash)
    }

    @discardableResult
    func moveMessage(_ id: UUID, to mailbox: Mailbox) -> Bool {
        moveMessages([id], to: mailbox)
    }

    func restoreDestination(for message: MailMessage) -> Mailbox {
        guard let source = message.trashedFrom, source != .trash, source != .starred else { return .inbox }
        return source
    }

    @discardableResult
    func restoreSelected() -> Bool {
        if selectedMessageIDs.count > 1 { return restoreMessages(selectedMessageIDs) }
        guard let selectedMessageID else { return false }
        return restoreMessage(selectedMessageID)
    }

    @discardableResult
    func restoreMessage(_ id: UUID) -> Bool {
        restoreMessages([id])
    }

    func recordMoveUndo(_ originals: [MailMessage]) {
        guard originals.count == 1, let original = originals.first else {
            lastMove = nil
            batchMoveUndo = (originals, selectedMessageIDs, selectedMessageID, mailboxViewKey.scope)
            return
        }
        batchMoveUndo = nil
        lastMove = MoveSnapshot(
            original: original,
            selectedMailbox: selectedMailbox,
            selectedAccount: selectedAccount,
            selectedMessageID: selectedMessageID,
            searchText: searchText,
            unreadOnly: unreadOnly,
            attachmentsOnly: attachmentsOnly,
            searchScope: searchScope,
            searchField: searchField,
            searchOrigin: searchOrigin,
            savedViewID: selectedSavedViewID,
            inboxSplitID: selectedInboxSplitID
        )
    }

    func reconcileSelection() {
        guard !isSearchingMessages, selectedMessageID != nil || !selectedMessageIDs.isEmpty else { return }
        if !isSearchActive, usesMailboxViewData || needsBackgroundSearch {
            guard let data = loadedMailboxView, data.key == mailboxViewKey else {
                startMailboxViewLoad()
                return
            }
            if pendingMoveSelection == nil, let lead = selectedMessageID, data.rowPositions[lead] != nil,
               selectedMessageIDs.allSatisfy({ data.rowPositions[$0] != nil }) { return }
        }
        reconcileSelection(in: filteredMessages)
    }

    func reconcileSelection(in visible: [MailMessage]) {
        let pending = pendingMoveSelection
        pendingMoveSelection = nil
        guard selectedMessageID != nil || !selectedMessageIDs.isEmpty else { return }
        let ids = Set(visible.map(\.id))
        let shouldAdvance = pending.map {
            !isSearchActive && $0.lead == selectedMessageID && $0.selection == selectedMessageIDs && $0.scope == mailboxViewKey.scope
        } ?? false
        let retained = selectedMessageIDs.intersection(ids)
        if retained != selectedMessageIDs { selectedMessageIDs = retained }
        if selectedMessageID.map(ids.contains) != true {
            isUpdatingSelection = true
            selectedMessageID = visible.first(where: { selectedMessageIDs.contains($0.id) })?.id
            isUpdatingSelection = false
            if shouldAdvance, selectedMessageID == nil, let lead = pending?.lead,
               let index = messages.firstIndex(where: { $0.id == lead }) {
                let next = messages[index...].first { ids.contains($0.id) }
                    ?? messages[..<index].last { ids.contains($0.id) }
                selectedMessageID = next?.id
                markSelectedRead()
            }
        }
    }

    func composedMessage(in mailbox: Mailbox) -> MailMessage {
        var message = MailMessage(
            id: editingDraftID ?? UUID(),
            sender: "Me",
            senderEmail: draftAccount.isLive ? draftProviderAccountEmail ?? draftAccount.email : draftAccount.email,
            initials: String(draftAccount.displayName.split(separator: " ").compactMap(\.first).prefix(2)).uppercased(),
            subject: draftSubject.isEmpty ? "(No subject)" : draftSubject,
            preview: draftBody.replacingOccurrences(of: "\n", with: " "),
            paragraphs: draftBody.components(separatedBy: "\n\n"),
            timeLabel: "Just now",
            mailbox: mailbox,
            account: draftAccount.rawValue,
            tint: "BBC8B9",
            isOutgoing: true,
            toRecipients: recipientsToSave(draftTo, mailbox: mailbox),
            ccRecipients: recipientsToSave(draftCc, mailbox: mailbox),
            bccRecipients: recipientsToSave(draftBcc, mailbox: mailbox),
            attachments: draftAttachments,
            conversationID: draftConversationID,
            bodyRTF: draftBodyRTF,
            workflow: MailWorkflowState(followUpAt: draftFollowUpAt, followUpOnlyIfNoReply: draftFollowUpOnlyIfNoReply,
                                        scheduledSendAt: draftSendAt),
            providerAccountEmail: draftAccount.isLive ? draftProviderAccountEmail ?? draftAccount.email : nil,
            providerThreadID: draftProviderThreadID,
            rfcMessageID: "<\(UUID().uuidString.lowercased())@postmere.local>",
            inReplyTo: draftInReplyTo,
            references: draftReferences
        )
        message.trackOpens = draftTrackOpens
        message.trackLinks = draftTrackLinks
        return message
    }

    func clearDraft() {
        draftTrackOpens = false
        draftTrackLinks = false
        editingDraftID = nil
        draftSendAt = nil
        draftFollowUpAt = nil
        draftFollowUpOnlyIfNoReply = true
        draftInReplyTo = nil
        draftReferences = []
        draftProviderThreadID = nil
        draftConversationID = UUID()
        draftAccount = defaultSendingAccount
        draftProviderAccountEmail = draftAccount.isLive ? draftAccount.email : nil
        draftTo = ""
        draftCc = ""
        draftBcc = ""
        draftSubject = ""
        draftBody = ""
        draftBodyRTF = nil
        draftAttachments = []
        composeTitle = "New message"
        initialDraft = currentDraft
    }

    var defaultSendingAccount: MailAccount {
        if let saved = UserDefaults.standard.string(forKey: "defaultSendingAccount").flatMap(MailAccount.init(rawValue:)), saved.isConnected { return saved }
        return MailAccount.sendingAccounts.first ?? .unassigned
    }

    private func recipientsToSave(_ input: String, mailbox: Mailbox) -> [String] {
        // Drafts preserve unfinished addresses exactly so Save Draft never drops typed text.
        if mailbox == .drafts { return input.isEmpty ? [] : [input] }
        return MailAddressList(input).addresses
    }

    private func replyRecipients(for message: MailMessage, includeAll: Bool) -> (to: [String], cc: [String]) {
        let ownAddresses = Set(MailAccount.allCases.map { $0.email.lowercased() })
        func uniqueOthers(_ addresses: [String], excluding: [String] = []) -> [String] {
            var seen = ownAddresses.union(excluding.map { $0.lowercased() })
            return addresses.filter { seen.insert($0.lowercased()).inserted }
        }
        let primary = message.isOutgoing ? message.toRecipients : [message.senderEmail]
        let to = uniqueOthers(primary + (includeAll && !message.isOutgoing ? message.toRecipients : []))
        let cc = includeAll ? uniqueOthers(message.ccRecipients, excluding: to) : []
        return (to, cc)
    }

    private func prefixedSubject(_ subject: String, prefix: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    private func initialBody(quoting message: MailMessage? = nil, forwarded: Bool = false) -> String {
        guard let message else {
            let body = initialSignatureBody(context: .newMessage)
            draftBodyRTF = body.rtfData
            return body.text
        }
        let sender = message.isOutgoing ? message.mailAccount.displayName : message.sender
        var headers = ["From: \(sender) <\(message.senderEmail)>", "Date: \(message.dateLabel), \(message.timeLabel)",
                       "Subject: \(message.subject)", "To: \(message.toRecipients.joined(separator: ", "))"]
        if !message.ccRecipients.isEmpty { headers.append("Cc: \(message.ccRecipients.joined(separator: ", "))") }
        let original = headers.joined(separator: "\n") + "\n\n" + message.paragraphs.joined(separator: "\n\n")
        let quoted = forwarded ? "---------- Forwarded message ----------\n" + original
            : "On \(message.dateLabel), \(sender) wrote:\n"
                + original.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        let body = initialSignatureBody(context: forwarded ? .forward : .reply, quotedText: quoted)
        draftBodyRTF = body.rtfData
        return body.text
    }

    func addDraftAttachments(from urls: [URL]) throws {
        var imported: [MailAttachment] = []
        do {
            for url in urls { imported.append(try MailAttachment.importFile(at: url, storageDirectory: attachmentStorageDirectory)) }
            draftAttachments.append(contentsOf: imported)
        } catch {
            for attachment in imported {
                if let url = attachment.localURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
            throw error
        }
    }

    func removeDraftAttachment(_ id: UUID) {
        draftAttachments.removeAll { $0.id == id }
    }
}

nonisolated struct MailDeparture: Equatable, Sendable {
    let id = UUID()
    let messageID: UUID?
    /// Nil when the message is coming back.
    let destination: Mailbox?
    let subject: String?
}
