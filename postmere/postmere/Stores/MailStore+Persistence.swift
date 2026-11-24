import Foundation

struct PersistenceFingerprint: Equatable {
    let mailboxRevision: Int
    let replyIndexVersion: Int
    let spamCheckResults: [String: StoredSpamCheck]
    let syncCursors: [String: String]
    let notificationCutoffs: [String: Date]
    let recoveredDraft: ActiveMailDraft?
}

private nonisolated struct MailboxSave: Sendable {
    let destination: MailPersistence
    let snapshot: MailStateSnapshot
    let revision: Int

    func write() -> Result<Void, Error> {
        Result { try destination.save(snapshot) }
    }
}

extension MailStore {
    var draftRecoveryAvailable: Bool {
        guard !isComposing, let draft = recoveredDraft else { return false }
        return !draft.account.isRemote || draft.account.remote != nil
    }
    var previousAccountDrafts: [MailMessage] {
        messages.filter { !$0.mailAccount.isRemote && ($0.mailbox == .drafts || $0.mailbox == .outbox) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    func reviewPreviousAccountDraft(id: UUID) {
        guard !isComposing, let message = previousAccountDrafts.first(where: { $0.id == id }) else { return }
        if message.mailbox == .outbox { restoreQueuedDraft(id) }
        else { beginEditingDraft(message) }
    }

    var attachmentStorageDirectory: URL { persistence?.attachmentDirectory ?? testAttachmentDirectory }

    var activeDraftSnapshot: ActiveMailDraft {
        ActiveMailDraft(editingMessageID: editingDraftID, conversationID: draftConversationID,
                        account: draftAccount, to: draftTo, cc: draftCc, bcc: draftBcc,
                        subject: draftSubject, body: draftBody, bodyRTF: draftBodyRTF,
                        attachments: draftAttachments, composeTitle: composeTitle,
                        sendAt: draftSendAt, followUpAt: draftFollowUpAt,
                        followUpOnlyIfNoReply: draftFollowUpOnlyIfNoReply,
                        inReplyTo: draftInReplyTo, references: draftReferences,
                        providerThreadID: draftProviderThreadID, providerAccountEmail: draftProviderAccountEmail,
                        trackOpens: draftTrackOpens, trackLinks: draftTrackLinks)
    }

    func loadPersistentState() {
        guard let persistence else { return }
        applyPersistentState(saveQueue.sync { Result { try persistence.load() } })
        if replyIndexVersion < MailStateSnapshot.currentReplyIndexVersion {
            MailReplyQueue.index(&messages, preservingLegacyFlags: replyIndexVersion == 0)
            replyIndexVersion = MailStateSnapshot.currentReplyIndexVersion
        }
    }

    func beginOpeningMailbox(_ persistence: MailPersistence) {
        isOpeningMailbox = true
        let queue = saveQueue
        openingTask = Task { [weak self] in
            let result = await withCheckedContinuation { continuation in
                // Metadata only: the mailbox opens as soon as its list can be shown.
                queue.async { continuation.resume(returning: Result { try persistence.load(bodies: false) }) }
            }
            guard let self else { return }
            self.applyPersistentState(result)
            self.showMailboxOverview()
            self.persistenceReady = true
            self.schedulePersistence()
            if self.preparesListWhileOpening, !self.searchableAccounts.isEmpty {
                await self.loadMailboxView()
            }
            self.isOpeningMailbox = false
            self.openingTask = nil
            self.fillStoredBodies(from: persistence)
        }
    }

    /// Rich bodies (HTML and RTF) kept in memory at most. Reading a message loads
    /// its rich body again from disk.
    static let richBodyBudget = 200

    /// Reads message bodies after the mailbox is showing, newest first, off the
    /// main thread. Reply detection, which reads bodies, runs once they are in.
    /// Plain text loads for every message; HTML and RTF only for the newest
    /// mail, drafts and the outbox. The rest stays on disk until it is read.
    private func fillStoredBodies(from persistence: MailPersistence) {
        let waiting = messages.filter { StoredMessageBody($0).isEmpty }.sorted { $0.sentAt > $1.sentAt }
        var warm = Set(waiting.prefix(Self.richBodyBudget).map(\.id))
        warm.formUnion(waiting.lazy.filter { $0.isDraft || $0.mailbox == .outbox }.map(\.id))
        bodySource = persistence
        bodyFillTask = Task { [weak self] in
            // The first list comes first; bodies must not compete with it.
            await self?.mailboxViewTask?.value
            var start = 0
            while start < waiting.count {
                let batch = Array(waiting[start..<min(start + 300, waiting.count)])
                start += batch.count
                let restored = await Task.detached(priority: .userInitiated) { [warm] in
                    persistence.loadBodies(for: batch, keepingRichFor: warm)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.applyStoredBodies(restored)
                let cold = restored.keys.filter { !warm.contains($0) }
                self.richBodyUnloadedIDs.formUnion(persistence.richBodiesOnDisk(cold))
                for id in restored.keys where warm.contains(id) { self.noteRichBodyUse(id) }
            }
            guard let self, !Task.isCancelled else { return }
            self.bodyFillTask = nil
            // Publish the cached inbox before the first on-device reply analysis.
            // New sync pages classify themselves while this migration runs.
            if self.replyIndexVersion < MailStateSnapshot.currentReplyIndexVersion {
                Task { await self.indexSavedReplyRequests() }
            }
        }
    }

    /// Fills bodies into messages that still lack one, and rich bodies into
    /// messages that had released theirs. Nothing here needs saving or
    /// syncing: the bodies came from disk unchanged.
    func applyStoredBodies(_ restored: [UUID: MailMessage]) {
        guard !restored.isEmpty else { return }
        var updated = messages
        var changed = false
        for index in updated.indices {
            guard let body = restored[updated[index].id] else { continue }
            if StoredMessageBody(updated[index]).isEmpty {
                StoredMessageBody(body).apply(to: &updated[index])
                updated[index].preview = body.preview
                changed = true
            } else if needsRichBody(updated[index]), body.bodyHTML != nil || body.bodyRTF != nil {
                updated[index].bodyHTML = body.bodyHTML
                updated[index].bodyRTF = body.bodyRTF
                changed = true
            }
            if body.bodyHTML != nil || body.bodyRTF != nil { richBodyUnloadedIDs.remove(body.id) }
        }
        guard changed else { return }
        applyingStoredBodies = true
        messages = updated
        applyingStoredBodies = false
    }

    func needsRichBody(_ message: MailMessage) -> Bool {
        richBodyUnloadedIDs.contains(message.id) && message.bodyHTML == nil && message.bodyRTF == nil
    }

    /// Opening a conversation reads any body or rich body it lacks right away.
    func loadBodiesNow(forConversationOf id: UUID) {
        guard let bodySource, let selected = messages.first(where: { $0.id == id }) else { return }
        let conversation = messages.filter { $0.conversationID == selected.conversationID }
        let waiting = conversation.filter { StoredMessageBody($0).isEmpty || needsRichBody($0) }
        if !waiting.isEmpty { applyStoredBodies(bodySource.loadBodies(for: waiting)) }
        for message in conversation { noteRichBodyUse(message.id) }
        releaseRichBodies(keeping: Set(conversation.map(\.id)))
    }

    private func noteRichBodyUse(_ id: UUID) {
        richBodyClock &+= 1
        richBodyUses[id] = richBodyClock
    }

    /// Releases the least recently read rich bodies beyond the budget. Only
    /// bodies a save has put on disk are released, so nothing is lost.
    private func releaseRichBodies(keeping current: Set<UUID>) {
        guard richBodyUses.count > Self.richBodyBudget, let bodySource else { return }
        let present = Set(messages.map(\.id))
        richBodyUses = richBodyUses.filter { present.contains($0.key) }
        guard richBodyUses.count > Self.richBodyBudget else { return }
        let excess = richBodyUses.count - Self.richBodyBudget
        let oldest = richBodyUses.filter { !current.contains($0.key) }.sorted { $0.value < $1.value }.prefix(excess).map(\.key)
        let releasable = bodySource.richBodiesOnDisk(oldest)
        guard !releasable.isEmpty else { return }
        var updated = messages
        var changed = false
        for index in updated.indices where releasable.contains(updated[index].id) {
            let message = updated[index]
            guard !message.isDraft, message.mailbox != .outbox, message.bodyHTML != nil || message.bodyRTF != nil else { continue }
            updated[index].bodyHTML = nil
            updated[index].bodyRTF = nil
            richBodyUnloadedIDs.insert(message.id)
            changed = true
        }
        // A body not saved yet keeps its place and is released on a later read.
        for id in releasable { richBodyUses.removeValue(forKey: id) }
        guard changed else { return }
        applyingStoredBodies = true
        messages = updated
        applyingStoredBodies = false
    }

    private func applyPersistentState(_ result: Result<MailStateSnapshot?, Error>) {
        do {
            guard let saved = try result.get() else { return }
            replyIndexVersion = saved.replyIndexVersion
            messages = saved.messages
            savedViews = saved.savedViews
            inboxSplits = saved.inboxSplits.map { split in
                var inboxSplit = split
                inboxSplit.criteria.mailbox = .inbox
                return inboxSplit
            }
            inboxSplitOverlapPolicy = saved.inboxSplitOverlapPolicy
            vipContacts = saved.vipContacts
            backendSyncCursors = saved.backendSyncCursors
            backendNotificationCutoffs = saved.backendNotificationCutoffs
            spamCheckResults = saved.spamCheckResults
            selectedInboxSplitID = inboxSplits.first(where: { $0.id == saved.selectedInboxSplitID && !$0.isHidden })?.id
            snippets = saved.snippets
            senderRules = saved.senderRules
            let legacyQueuedMessageIDs: Set<UUID>
            if saved.outgoingQueue.isEmpty {
                legacyQueuedMessageIDs = []
            } else {
                let queuedIDs = Set(saved.outgoingQueue.map(\.messageID))
                legacyQueuedMessageIDs = Set(saved.messages.lazy.filter { queuedIDs.contains($0.id) && !$0.mailAccount.isRemote }.map(\.id))
            }
            outgoingQueue = saved.outgoingQueue.map { item in
                var recovered = item
                if legacyQueuedMessageIDs.contains(item.id) {
                    recovered = stoppedLegacySend(recovered)
                } else if recovered.status == .delivering && recovered.serverJobID == nil {
                    recovered.status = .failed
                    recovered.lastError = "Delivery was interrupted. Check Sent before retrying to avoid sending twice."
                }
                return recovered
            }
            recoveredDraft = saved.activeDraft
            senderScreeningEnabled = saved.senderScreeningEnabled
        } catch {
            // Never replace a corrupt or unsupported mailbox with fresh sample data.
            messages = []
            persistenceBlocked = true
            persistenceError = "Postmere could not open your saved mailbox: \(error.localizedDescription) Your saved file has not been changed."
        }
    }

    private func nextSave() -> MailboxSave? {
        guard persistenceReady, persistenceSuspended == 0, !persistenceBlocked else { return nil }
        preserveRecoveredDraftDuringComposition()
        guard let persistence else { return nil }
        pendingSave?.cancel()
        pendingSave = nil
        saveRevision += 1
        lastQueuedFingerprint = persistenceFingerprint
        return MailboxSave(destination: persistence, snapshot: mailboxSnapshot, revision: saveRevision)
    }

    @discardableResult
    private func finishSave(_ result: Result<Void, Error>, revision: Int) -> Bool {
        switch result {
        case .success:
            if revision == saveRevision { persistenceError = nil }
            return true
        case .failure(let error):
            if revision == saveRevision {
                persistenceError = "Changes could not be saved: \(error.localizedDescription) Keep Postmere open and retry after resolving the storage problem."
            }
            return false
        }
    }

    @discardableResult
    func persistState() -> Bool {
        guard let save = nextSave() else { return !persistenceBlocked || !persistenceReady || persistenceSuspended > 0 }
        return finishSave(saveQueue.sync { save.write() }, revision: save.revision)
    }

    /// A sync cursor or provider operation can await a durable write while the main actor handles input.
    func persistStateAsync() async -> Bool {
        guard let save = nextSave() else { return !persistenceBlocked || !persistenceReady || persistenceSuspended > 0 }
        let result = await withCheckedContinuation { continuation in
            saveQueue.async { continuation.resume(returning: save.write()) }
        }
        return finishSave(result, revision: save.revision)
    }

    private var mailboxSnapshot: MailStateSnapshot {
        var snapshot = MailStateSnapshot(messages: messages, savedViews: savedViews,
                snippets: snippets, senderRules: senderRules, outgoingQueue: outgoingQueue,
                activeDraft: isComposing ? activeDraftSnapshot : recoveredDraft,
                senderScreeningEnabled: senderScreeningEnabled, inboxSplits: inboxSplits,
                selectedInboxSplitID: selectedInboxSplitID, inboxSplitOverlapPolicy: inboxSplitOverlapPolicy,
                vipContacts: vipContacts, backendSyncCursors: backendSyncCursors,
                backendNotificationCutoffs: backendNotificationCutoffs)
        snapshot.replyIndexVersion = replyIndexVersion
        snapshot.spamCheckResults = spamCheckResults
        return snapshot
    }

    /// Coalesce ordinary edits. Commits that must precede delivery and the final quit flush share this queue.
    func schedulePersistence() {
        guard let save = nextSave() else { return }
        let work = DispatchWorkItem { @Sendable [weak self] in
            let result = save.write()
            Task { @MainActor [weak self] in
                guard let self, self.saveRevision == save.revision else { return }
                self.pendingSave = nil
                self.finishSave(result, revision: save.revision)
            }
        }
        pendingSave = work
        saveQueue.async(execute: work)
    }

    @discardableResult
    func flushPersistence() -> Bool { persistState() }

    /// Values that change without queueing a save themselves. Everything else
    /// queues one on every change, so an unchanged fingerprint means the
    /// newest state is already written or on its way.
    var persistenceFingerprint: PersistenceFingerprint {
        PersistenceFingerprint(mailboxRevision: mailboxDataRevision, replyIndexVersion: replyIndexVersion,
                               spamCheckResults: spamCheckResults, syncCursors: backendSyncCursors,
                               notificationCutoffs: backendNotificationCutoffs, recoveredDraft: recoveredDraft)
    }

    /// Queues a final save only if something changed since the last one, then
    /// calls `done` on the main actor once every queued write is on disk.
    func finishPersistenceForQuit(_ done: @escaping @MainActor @Sendable () -> Void) {
        if persistenceFingerprint != lastQueuedFingerprint || isComposing { schedulePersistence() }
        saveQueue.async { Task { @MainActor in done() } }
    }

    func retryPersistence() {
        if persistenceBlocked {
            persistenceReady = false
            persistenceBlocked = false
            loadPersistentState()
            persistenceReady = true
        }
        persistState()
    }

    func draftChanged() {
        if isComposing { schedulePersistence() }
    }

    func recoverDraft() {
        guard draftRecoveryAvailable, let draft = recoveredDraft else { return }
        persistenceSuspended += 1
        editingDraftID = draft.editingMessageID
        draftConversationID = draft.conversationID
        draftAccount = draft.account
        draftTo = draft.to
        draftCc = draft.cc
        draftBcc = draft.bcc
        draftSubject = draft.subject
        draftBody = draft.body
        draftBodyRTF = draft.bodyRTF
        draftAttachments = draft.attachments
        composeTitle = draft.composeTitle
        draftSendAt = draft.sendAt
        draftFollowUpAt = draft.followUpAt
        draftFollowUpOnlyIfNoReply = draft.followUpOnlyIfNoReply
        draftInReplyTo = draft.inReplyTo
        draftReferences = draft.references
        draftProviderThreadID = draft.providerThreadID
        draftProviderAccountEmail = draft.providerAccountEmail
        draftTrackOpens = draft.trackOpens ?? false
        draftTrackLinks = draft.trackLinks ?? false
        initialDraft = DraftSnapshot()
        recoveredDraft = nil
        isComposing = true
        persistenceSuspended -= 1
        persistState()
        lastAction = "Recovered your unfinished message"
    }

    func discardRecoveredDraft() {
        guard draftRecoveryAvailable else { return }
        recoveredDraft = nil
        persistState()
    }

    /// The persisted active-draft slot is singular. Before another workspace
    /// begins composing, retain its hidden recovery as a normal scoped draft.
    private func preserveRecoveredDraftDuringComposition() {
        guard isComposing, let draft = recoveredDraft else { return }
        let existingIndex = messages.firstIndex {
            $0.id == draft.editingMessageID && $0.account == draft.account.rawValue && $0.mailbox == .drafts
        }
        var message = existingIndex.map { messages[$0] } ?? MailMessage(
            sender: "Me", senderEmail: draft.providerAccountEmail ?? draft.account.email, initials: "",
            subject: draft.subject, preview: "", paragraphs: [], timeLabel: "Just now",
            mailbox: .drafts, account: draft.account.rawValue, isOutgoing: true,
            conversationID: draft.conversationID)
        message.subject = draft.subject
        message.preview = draft.body.replacingOccurrences(of: "\n", with: " ")
        message.paragraphs = draft.body.components(separatedBy: "\n\n")
        message.bodyRTF = draft.bodyRTF
        message.bodyHTML = nil
        message.toRecipients = draft.to.isEmpty ? [] : [draft.to]
        message.ccRecipients = draft.cc.isEmpty ? [] : [draft.cc]
        message.bccRecipients = draft.bcc.isEmpty ? [] : [draft.bcc]
        message.attachments = draft.attachments
        message.conversationID = draft.conversationID
        message.providerThreadID = draft.providerThreadID
        message.providerAccountEmail = draft.providerAccountEmail
        message.inReplyTo = draft.inReplyTo
        message.references = draft.references
        message.trackOpens = draft.trackOpens
        message.trackLinks = draft.trackLinks
        message.workflow.scheduledSendAt = draft.sendAt
        message.workflow.followUpAt = draft.followUpAt
        message.workflow.followUpOnlyIfNoReply = draft.followUpOnlyIfNoReply
        persistenceSuspended += 1
        let previousSuppression = suppressRemoteMutations
        suppressRemoteMutations = true
        if let existingIndex { messages[existingIndex] = message }
        else { messages.insert(message, at: 0) }
        recoveredDraft = nil
        suppressRemoteMutations = previousSuppression
        persistenceSuspended -= 1
    }

    func syncProviderChanges(from previous: [MailMessage]) {
        guard persistenceReady, !suppressRemoteMutations else { return }
        let indices = Dictionary(uniqueKeysWithValues: previous.indices.lazy.map { (previous[$0].id, $0) })
        for message in messages {
            if let index = indices[message.id] { syncProviderChange(from: previous[index], to: message) }
        }
    }

    func syncProviderChange(from old: MailMessage, to message: MailMessage) {
        guard old.isUnread != message.isUnread || old.isStarred != message.isStarred || old.mailbox != message.mailbox,
              persistenceReady, !suppressRemoteMutations, message.mailAccount.isRemote,
              message.providerMessageID != nil, !message.isDeletedOnProvider else { return }
        var expected = providerOverrides[message.id] ?? ProviderMessageOverride()
        if old.isUnread != message.isUnread { expected.isUnread = message.isUnread }
        if old.isStarred != message.isStarred { expected.isStarred = message.isStarred }
        if old.mailbox != message.mailbox { expected.mailbox = message.mailbox }
        providerOverrides[message.id] = expected
        let priorTask = remoteMutationTasks[message.id]
        remoteMutationTasks[message.id] = Task { [weak self] in
            await priorTask?.value
            guard let self else { return }
            do {
                guard let remoteMutation = self.remoteMutation else { throw MailStorageError.missingSender }
                try await remoteMutation(old, message)
            } catch {
                self.removeFailedProviderOverride(from: old, to: message)
                self.operationError = "The mail provider could not save that change: \(error.localizedDescription)"
                self.lastAction = "Provider change failed"
                guard let index = self.messages.firstIndex(where: { $0.id == message.id }) else { return }
                var current = self.messages[index]
                if current.isUnread == message.isUnread { current.isUnread = old.isUnread }
                if current.isStarred == message.isStarred { current.isStarred = old.isStarred }
                if old.mailbox != message.mailbox, current.mailbox == message.mailbox {
                    current.mailbox = old.mailbox
                    current.trashedFrom = old.trashedFrom
                    if old.workflow.screeningState != message.workflow.screeningState,
                       current.workflow.screeningState == message.workflow.screeningState {
                        current.workflow.screeningState = old.workflow.screeningState
                    }
                    if old.workflow.snoozedUntil != message.workflow.snoozedUntil,
                       current.workflow.snoozedUntil == message.workflow.snoozedUntil {
                        current.workflow.snoozedUntil = old.workflow.snoozedUntil
                    }
                }
                self.suppressRemoteMutations = true
                self.messages[index] = current
                self.suppressRemoteMutations = false
                self.reconcileSelection()
            }
        }
    }

    func removeFailedProviderOverride(from old: MailMessage, to message: MailMessage) {
        guard var pending = providerOverrides[message.id] else { return }
        if old.isUnread != message.isUnread && pending.isUnread == message.isUnread { pending.isUnread = nil }
        if old.isStarred != message.isStarred && pending.isStarred == message.isStarred { pending.isStarred = nil }
        if old.mailbox != message.mailbox && pending.mailbox == message.mailbox { pending.mailbox = nil }
        providerOverrides[message.id] = pending.isEmpty ? nil : pending
    }
}
