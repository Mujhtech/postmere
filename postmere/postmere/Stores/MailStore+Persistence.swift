import Foundation

extension MailStore {
    var draftRecoveryAvailable: Bool { recoveredDraft != nil && !isComposing }
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
        do {
            guard let saved = try persistence.load() else { return }
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
            selectedInboxSplitID = inboxSplits.first(where: { $0.id == saved.selectedInboxSplitID && !$0.isHidden })?.id
            snippets = saved.snippets
            senderRules = saved.senderRules
            outgoingQueue = saved.outgoingQueue.map { item in
                var recovered = item
                if let message = saved.messages.first(where: { $0.id == item.id }), !message.mailAccount.isRemote {
                    recovered.status = .failed
                    recovered.lastError = MailStorageError.workspaceRequired.localizedDescription
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

    @discardableResult
    func persistState() -> Bool {
        guard persistenceReady, persistenceSuspended == 0 else { return true }
        guard let persistence else { return true }
        guard !persistenceBlocked else { return false }
        do {
            try persistence.save(MailStateSnapshot(messages: messages, savedViews: savedViews,
                snippets: snippets, senderRules: senderRules, outgoingQueue: outgoingQueue,
                activeDraft: isComposing ? activeDraftSnapshot : recoveredDraft,
                senderScreeningEnabled: senderScreeningEnabled, inboxSplits: inboxSplits,
                selectedInboxSplitID: selectedInboxSplitID, inboxSplitOverlapPolicy: inboxSplitOverlapPolicy,
                vipContacts: vipContacts, backendSyncCursors: backendSyncCursors,
                backendNotificationCutoffs: backendNotificationCutoffs))
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Changes could not be saved: \(error.localizedDescription) Keep Postmere open and retry after resolving the storage problem."
            return false
        }
    }

    @discardableResult
    func flushPersistence() -> Bool { persistState() }

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
        if isComposing { persistState() }
    }

    func recoverDraft() {
        guard !isComposing, let draft = recoveredDraft else { return }
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
        recoveredDraft = nil
        persistState()
    }

    func syncProviderChanges(from previous: [MailMessage]) {
        guard persistenceReady, !suppressRemoteMutations else { return }
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for message in messages where message.mailAccount.isRemote && message.providerMessageID != nil && !message.isDeletedOnProvider {
            guard let old = before[message.id],
                  old.isUnread != message.isUnread || old.isStarred != message.isStarred || old.mailbox != message.mailbox else { continue }
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
                    if current.mailbox == message.mailbox { current.mailbox = old.mailbox; current.trashedFrom = old.trashedFrom }
                    self.suppressRemoteMutations = true
                    self.messages[index] = current
                    self.suppressRemoteMutations = false
                    self.reconcileSelection()
                }
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

    func preservePendingProviderChanges(in message: inout MailMessage) {
        guard var pending = providerOverrides[message.id] else { return }
        if let value = pending.isUnread {
            if message.isUnread == value { pending.isUnread = nil } else { message.isUnread = value }
        }
        if let value = pending.isStarred {
            if message.isStarred == value { pending.isStarred = nil } else { message.isStarred = value }
        }
        if let value = pending.mailbox {
            if message.mailbox == value { pending.mailbox = nil } else { message.mailbox = value }
        }
        providerOverrides[message.id] = pending.isEmpty ? nil : pending
    }
}
