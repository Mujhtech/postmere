import Foundation

extension MailStore {
    var latestUndoableSend: OutgoingMailItem? {
        outgoingQueue.last { $0.status == .pending && $0.undoUntil > .now }
    }
    var canUndoSend: Bool { latestUndoableSend != nil }

    func queueCurrentDraft(now: Date = .now) {
        guard canSendDraft else { return }
        let oldMessages = messages
        let oldQueue = outgoingQueue
        let oldComposing = isComposing
        let delay = max(5, min(60, UserDefaults.standard.object(forKey: "undoSendDelay") as? Double ?? 10))
        let deadline = now.addingTimeInterval(delay)
        var queued = composedMessage(in: .outbox)
        if draftAccount.isRemote {
            // Matches the server MIME builder, including Microsoft sends that
            // return no provider message ID in their acceptance response.
            queued.rfcMessageID = "<\(queued.id.uuidString.lowercased())@postmere.local>"
        }
        queued.trackOpens = draftAccount.isRemote && draftTrackOpens
        queued.trackLinks = draftAccount.isRemote && draftTrackLinks
        queued.sentAt = now
        let item = OutgoingMailItem(messageID: queued.id, queuedAt: now, undoUntil: deadline,
                                    scheduledAt: max(deadline, draftSendAt ?? deadline))
        persistenceSuspended += 1
        if let editingDraftID { messages.removeAll { $0.id == editingDraftID } }
        messages.insert(queued, at: 0)
        outgoingQueue.append(item)
        isComposing = false
        persistenceSuspended -= 1
        guard persistState() else {
            persistenceSuspended += 1
            messages = oldMessages
            outgoingQueue = oldQueue
            isComposing = oldComposing
            persistenceSuspended -= 1
            return
        }
        clearDraft()
        reconcileSelection()
        lastAction = "Uploading to your server · keep Postmere open until accepted"
    }

    func undoSend(_ id: UUID) {
        guard let item = outgoingQueue.first(where: { $0.id == id }), item.status == .pending, item.undoUntil > .now else { return }
        cancelQueuedSend(id)
    }

    func undoLastSend() {
        if let item = latestUndoableSend { undoSend(item.id) }
    }

    func cancelQueuedSend(_ id: UUID) {
        guard outgoingQueue.contains(where: { $0.id == id && $0.status != .delivering }) else { return }
        if messages.first(where: { $0.id == id })?.mailAccount.isRemote == true {
            guard let onCancelRemoteSend else { operationError = BackendQueueError.disconnected; return }
            onCancelRemoteSend(id)
            return
        }
        restoreQueuedDraft(id)
    }

    func restoreQueuedDraft(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let oldMessages = messages
        let oldQueue = outgoingQueue
        persistenceSuspended += 1
        outgoingQueue.removeAll { $0.id == id }
        messages[index].mailbox = .drafts
        let draft = messages[index]
        persistenceSuspended -= 1
        guard persistState() else {
            persistenceSuspended += 1
            messages = oldMessages
            outgoingQueue = oldQueue
            persistenceSuspended -= 1
            return
        }
        if !isComposing && !draftRecoveryAvailable { beginEditingDraft(draft) }
        lastAction = "Send cancelled · saved in Drafts"
        reconcileSelection()
    }

    func retrySend(_ id: UUID) {
        guard let index = outgoingQueue.firstIndex(where: { $0.id == id && $0.status == .failed }) else { return }
        if messages.first(where: { $0.id == id })?.mailAccount.isRemote == true {
            guard let onRetryRemoteSend else { operationError = BackendQueueError.disconnected; return }
            onRetryRemoteSend(id)
            return
        }
        outgoingQueue[index].status = .failed
        outgoingQueue[index].lastError = MailStorageError.workspaceRequired.localizedDescription
        operationError = MailStorageError.workspaceRequired.localizedDescription
    }

    /// Delivery belongs to the server. Quarantine legacy local sends without
    /// changing their contents or transferring them to another account.
    func processDueWork(now: Date = .now) async {
        processWorkflowDates(now: now)
        for index in outgoingQueue.indices {
            guard outgoingQueue[index].status == .pending || outgoingQueue[index].status == .delivering,
                  let message = messages.first(where: { $0.id == outgoingQueue[index].id }),
                  !message.mailAccount.isRemote else { continue }
            outgoingQueue[index].status = .failed
            outgoingQueue[index].lastError = MailStorageError.workspaceRequired.localizedDescription
        }
    }

    func processWorkflowDates(now: Date = .now) {
        var updated = messages
        var changed = false
        var dueConversations: Set<String> = []
        for index in updated.indices {
            guard isAccountVisible(updated[index]), !updated[index].isDeletedOnProvider else { continue }
            if let wake = updated[index].workflow.snoozedUntil, wake <= now {
                let original = updated[index]
                if !original.isDraft && original.mailbox != .trash && original.mailbox != .outbox,
                   dueConversations.insert(conversationKey(for: original)).inserted {
                    onSnoozeDue?(original, wake)
                }
                updated[index].workflow.snoozedUntil = nil
                if updated[index].mailbox == .archive { updated[index].mailbox = .inbox }
                if !updated[index].isDraft && updated[index].mailbox != .trash { updated[index].isUnread = true }
                changed = true
            }
            let message = updated[index]
            if message.workflow.followUpAt != nil && message.workflow.followUpOnlyIfNoReply,
               let reference = message.workflow.followUpReferenceDate,
               messages.contains(where: {
                   $0.conversationID == message.conversationID && sameMailAccount($0, message)
                   && !$0.isOutgoing && !$0.isDraft && $0.sentAt > reference
               }) {
                updated[index].workflow.followUpAt = nil
                updated[index].workflow.followUpReferenceDate = nil
                changed = true
            }
        }
        if changed { messages = updated; reconcileSelection() }
    }

    func mergeIncoming(_ incoming: [MailMessage]) {
        mergeProviderMessages(incoming, account: nil)
    }

    func mergeProviderMessages(_ incoming: [MailMessage], account: String? = nil) {
        var combined = messages
        for var message in incoming where account == nil || message.account == account {
            if message.providerMessageID != nil { message.providerDeletedAt = nil }
            let existingIndex = combined.firstIndex {
                sameMailAccount($0, message) && ($0.id == message.id
                    || (message.providerMessageID != nil && $0.providerMessageID == message.providerMessageID)
                    || (message.rfcMessageID != nil && $0.rfcMessageID == message.rfcMessageID))
            }
            if let existingIndex {
                let previous = combined[existingIndex]
                message.id = previous.id
                message.conversationID = previous.conversationID
                message.workflow = previous.workflow
                message.backendOutboxID = previous.backendOutboxID
                message.trackOpens = previous.trackOpens
                message.trackLinks = previous.trackLinks
                preservePendingProviderChanges(in: &message)
                message.attachments = message.attachments.map { attachment in
                    var result = attachment
                    if let old = previous.attachments.first(where: {
                        $0.id == attachment.id || (attachment.providerAttachmentID != nil && $0.providerAttachmentID == attachment.providerAttachmentID)
                    }) { result.localURL = old.localURL ?? result.localURL }
                    return result
                }
                if previous.mailbox != .outbox { combined[existingIndex] = message }
                else if message.backendMessageID != nil {
                    // Cache sync may see Sent before the outbox poll does. Keep
                    // queue state, but retain the identifiers before its cursor
                    // advances past this message permanently.
                    var queued = previous
                    queued.backendMessageID = message.backendMessageID
                    queued.providerMessageID = message.providerMessageID
                    queued.providerThreadID = message.providerThreadID
                    queued.rfcMessageID = message.rfcMessageID
                    combined[existingIndex] = queued
                }
            } else {
                if let context = combined.first(where: {
                    sameMailAccount($0, message) && (($0.providerThreadID != nil && $0.providerThreadID == message.providerThreadID)
                        || $0.conversationID == message.conversationID)
                }) {
                    message.conversationID = context.conversationID
                    message.workflow = context.workflow
                }
                if !message.isOutgoing {
                    if let rule = senderRules.first(where: { matchesRule($0, message: message) }) { applyRule(rule, to: &message) }
                    else if senderScreeningEnabled { message.workflow.screeningState = .pending }
                }
                combined.append(message)
            }
        }
        suppressRemoteMutations = true
        messages = combined.sorted { $0.sentAt > $1.sentAt }
        suppressRemoteMutations = false
        processWorkflowDates()
        reconcileSelection()
    }

    func markProviderMessagesUnavailable(ids: Set<String>, accountEmail: String) {
        guard !ids.isEmpty else { return }
        var updated = messages
        var changed = false
        for index in updated.indices where updated[index].providerAccountEmail?.caseInsensitiveCompare(accountEmail) == .orderedSame {
            guard let providerID = updated[index].providerMessageID, ids.contains(providerID), !updated[index].isDeletedOnProvider else { continue }
            updated[index].isDeletedOnProvider = true
            providerOverrides[updated[index].id] = nil
            changed = true
        }
        guard changed else { return }
        suppressRemoteMutations = true
        messages = updated
        suppressRemoteMutations = false
        reconcileSelection()
    }
}

private enum BackendQueueError {
    static let disconnected = "Connect to your Postmere workspace to manage this send."
}
