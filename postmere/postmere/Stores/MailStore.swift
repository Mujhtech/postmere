import Foundation
import Observation

/// Durable mailbox state. Explicit message fixtures keep persistence disabled for previews and tests.
@MainActor
@Observable
final class MailStore {
    var messages: [MailMessage] { didSet { persistState(); syncProviderChanges(from: oldValue) } }
    var selectedMailbox: Mailbox = .inbox
    var selectedAccount: String?
    var selectedMessageID: UUID? {
        didSet {
            if !isUpdatingSelection { selectedMessageIDs = selectedMessageID.map { [$0] } ?? [] }
        }
    }
    var selectedMessageIDs: Set<UUID> = []
    @ObservationIgnored var isUpdatingSelection = false
    var searchText = "" {
        didSet { reconcileSelection() }
    }
    var unreadOnly = false {
        didSet { reconcileSelection() }
    }
    var attachmentsOnly = false {
        didSet { reconcileSelection() }
    }
    var searchScope: MailSearchScope = .currentMailbox {
        didSet { reconcileSelection() }
    }
    var searchField: MailSearchField = .all {
        didSet { reconcileSelection() }
    }
    var isComposing = false { didSet { persistState() } }
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
    var lastAction: String?
    var editingDraftID: UUID?
    var draftConversationID = UUID()
    var initialDraft = DraftSnapshot()
    private var lastMove: MoveSnapshot?
    var batchMoveUndo: [MailMessage]?
    var batchMoveSelection: Set<UUID> = []
    var savedViews: [SavedInboxView] = [] { didSet { persistState() } }
    var inboxSplits: [InboxSplit] = InboxSplit.defaults { didSet { persistState(); reconcileSelection() } }
    var selectedInboxSplitID: UUID? { didSet { persistState(); reconcileSelection() } }
    var inboxSplitOverlapPolicy: InboxSplitOverlapPolicy = .firstMatch { didSet { persistState(); reconcileSelection() } }
    var vipContacts: [VIPContact] = [] { didSet { persistState(); reconcileSelection() } }
    var snippets: [MailSnippet] = [] { didSet { persistState() } }
    var senderRules: [SenderRule] = [] { didSet { persistState(); onNotificationPolicyChanged?() } }
    var outgoingQueue: [OutgoingMailItem] = [] { didSet { persistState() } }
    var senderScreeningEnabled = false { didSet { persistState(); onNotificationPolicyChanged?() } }
    var selectedSavedViewID: UUID?
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
    @ObservationIgnored var suppressRemoteMutations = false
    @ObservationIgnored var remoteMutationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var persistence: MailPersistence?
    @ObservationIgnored var searchQueryCache: [String: MailSearchQuery] = [:]
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
        let messageID: UUID
        let mailbox: Mailbox
        let trashedFrom: Mailbox?
        let isUnread: Bool
        let selectedMailbox: Mailbox
        let selectedAccount: String?
        let selectedMessageID: UUID?
        let searchText: String
        let unreadOnly: Bool
        let attachmentsOnly: Bool
        let searchScope: MailSearchScope
        let searchField: MailSearchField
    }

    init(messages: [MailMessage]? = nil, persistenceURL: URL? = nil) {
        self.isPreview = messages != nil
        self.messages = messages ?? []
        persistence = persistenceURL.map(MailPersistence.init(fileURL:))
            ?? (messages == nil ? MailPersistence(fileURL: MailPersistence.defaultURL) : nil)
        loadPersistentState()
        selectedMessageID = filteredMessages.first?.id
        persistenceReady = true
        if !persistenceBlocked { persistState() }
    }

    var filteredMessages: [MailMessage] {
        let query = parsedSearchQuery
        let searchesAll = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchScope == .allMailboxes
        let splitConversationKeys: Set<String>?
        if !searchesAll, selectedSavedView == nil, selectedMailbox == .inbox,
           let splitID = selectedInboxSplitID, visibleInboxSplits.contains(where: { $0.id == splitID }) {
            splitConversationKeys = matchingSplitConversationKeys(splitID)
        } else { splitConversationKeys = nil }
        let matches = messages.filter { message in
            let isInCurrentMailbox = selectedSavedView.map { matchesSavedView(message, criteria: $0.criteria) }
                ?? matchesMailbox(message, mailbox: selectedMailbox)
            let isInMailbox = searchesAll || isInCurrentMailbox
            let matchesSplit = splitConversationKeys.map { $0.contains(conversationKey(for: message)) } ?? true
            let matchesAccount = (selectedAccount == nil || message.account == selectedAccount) && isAccountVisible(message)
            return isInMailbox && matchesSplit && matchesAccount && query.matches(message, context: searchContext)
                && (!unreadOnly || message.isUnread) && (!attachmentsOnly || !message.attachments.isEmpty)
        }
        let mailbox = selectedSavedView?.criteria.mailbox ?? selectedMailbox
        return (splitConversationKeys != nil || mailbox.isConversationQueue) && !searchesAll
            ? deduplicatedConversations(matches) : matches
    }

    var selectedMessage: MailMessage? {
        messages.first { $0.id == selectedMessageID && isAccountVisible($0) }
    }

    /// Conversation context is independent of mailbox/search filters; actions still target one message.
    func conversationMessages(for message: MailMessage) -> [MailMessage] {
        messages.filter {
            $0.conversationID == message.conversationID && sameMailAccount($0, message)
                && !$0.isDraft && !$0.isDeletedOnProvider && ($0.mailbox != .trash || $0.id == message.id)
        }
        .sorted {
            if $0.sentAt != $1.sentAt { return $0.sentAt < $1.sentAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func conversationCount(for message: MailMessage) -> Int {
        conversationMessages(for: message).count
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
        selectedMessageID = message.id
        markSelectedRead()
    }

    func markSelectedRead() {
        // Keep the unread results stable until the user leaves this filter.
        guard !unreadOnly,
              let index = messages.firstIndex(where: { $0.id == selectedMessageID }) else { return }
        messages[index].isUnread = false
    }

    func selectAdjacent(_ offset: Int) {
        let visible = filteredMessages
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedMessageID } ?? -1
        select(visible[max(0, min(index + offset, visible.count - 1))])
    }

    func selectMailbox(_ mailbox: Mailbox) {
        selectedSavedViewID = nil
        selectedMailbox = mailbox
        selectedAccount = nil
        clearFilters()
        selectedMessageID = filteredMessages.first?.id
        if let message = selectedMessage { select(message) }
    }

    func selectAccount(_ account: String?) {
        selectedSavedViewID = nil
        selectedMailbox = .inbox
        selectedAccount = account
        clearFilters()
        selectedMessageID = filteredMessages.first?.id
        if let message = selectedMessage { select(message) }
    }

    func clearFilters() {
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
        if undoBatchMove() { lastMove = nil; return }
        guard let lastMove,
              let index = messages.firstIndex(where: { $0.id == lastMove.messageID }) else { return }
        messages[index].mailbox = lastMove.mailbox
        messages[index].trashedFrom = lastMove.trashedFrom
        messages[index].isUnread = lastMove.isUnread
        selectedMailbox = lastMove.selectedMailbox
        selectedAccount = lastMove.selectedAccount
        searchText = lastMove.searchText
        unreadOnly = lastMove.unreadOnly
        attachmentsOnly = lastMove.attachmentsOnly
        searchScope = lastMove.searchScope
        searchField = lastMove.searchField
        selectedMessageID = lastMove.selectedMessageID
        reconcileSelection()
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
        [.inbox, .archive, .trash].contains(mailbox) && message.mailbox != mailbox
            && message.mailbox != .outbox && (!message.isDraft || mailbox == .trash)
    }

    @discardableResult
    func moveMessage(_ id: UUID, to mailbox: Mailbox) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              canMoveMessage(messages[index], to: mailbox) else { return false }
        return performMove(at: index, to: mailbox)
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
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].mailbox == .trash else { return false }
        return performMove(at: index, to: restoreDestination(for: messages[index]))
    }

    private func performMove(at index: Int, to mailbox: Mailbox) -> Bool {
        batchMoveUndo = nil
        let id = messages[index].id
        lastMove = MoveSnapshot(
            messageID: id,
            mailbox: messages[index].mailbox,
            trashedFrom: messages[index].trashedFrom,
            isUnread: messages[index].isUnread,
            selectedMailbox: selectedMailbox,
            selectedAccount: selectedAccount,
            selectedMessageID: selectedMessageID,
            searchText: searchText,
            unreadOnly: unreadOnly,
            attachmentsOnly: attachmentsOnly,
            searchScope: searchScope,
            searchField: searchField
        )
        let oldPosition = filteredMessages.firstIndex(where: { $0.id == id }) ?? 0
        messages[index].trashedFrom = mailbox == .trash ? messages[index].mailbox : nil
        messages[index].mailbox = mailbox
        messages[index].isUnread = false
        let remaining = filteredMessages
        if selectedMessageID == id && !remaining.contains(where: { $0.id == id }) {
            selectedMessageID = remaining.isEmpty ? nil : remaining[min(oldPosition, remaining.count - 1)].id
            markSelectedRead()
        }
        reconcileSelection()
        lastAction = "Moved to \(mailbox.title)"
        return true
    }

    func reconcileSelection() {
        selectedMessageIDs.formIntersection(Set(filteredMessages.map(\.id)))
        if !filteredMessages.contains(where: { $0.id == selectedMessageID }) {
            isUpdatingSelection = true
            selectedMessageID = filteredMessages.first(where: { selectedMessageIDs.contains($0.id) })?.id
            isUpdatingSelection = false
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

    private var defaultSendingAccount: MailAccount {
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
