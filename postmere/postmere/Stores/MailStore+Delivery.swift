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
        outgoingQueue[index] = stoppedLegacySend(outgoingQueue[index])
        operationError = outgoingQueue[index].lastError
    }

    /// Delivery belongs to the server. Quarantine legacy local sends without
    /// changing their contents or transferring them to another account.
    func processDueWork(now: Date = .now) async {
        processWorkflowDates(now: now)
        for index in outgoingQueue.indices {
            guard outgoingQueue[index].status == .pending || outgoingQueue[index].status == .delivering,
                  let message = messages.first(where: { $0.id == outgoingQueue[index].id }),
                  !message.mailAccount.isRemote else { continue }
            outgoingQueue[index] = stoppedLegacySend(outgoingQueue[index])
        }
    }

    func stoppedLegacySend(_ item: OutgoingMailItem) -> OutgoingMailItem {
        var result = item
        var details = item.lastError ?? ""
        if item.status == .delivering && !details.contains("Check Sent") {
            details += (details.isEmpty ? "" : " ") + "Previous delivery was interrupted and may have reached the provider. Check Sent before sending again."
        }
        let notice = MailStorageError.workspaceRequired.localizedDescription
        if !details.contains(notice) { details += (details.isEmpty ? "" : " ") + notice }
        result.status = .failed
        result.lastError = details
        return result
    }

    func processWorkflowDates(now: Date = .now) {
        var updated = messages
        var changed = false
        var dueConversations: Set<String> = []
        for index in updated.indices {
            guard updated[index].workflow.snoozedUntil != nil || updated[index].workflow.followUpAt != nil else { continue }
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
        guard !incoming.isEmpty else { return }
        installMerge(merge(incoming, into: mergeInputs), processDates: true)
    }

    private struct MergeInputs: Sendable {
        let messages: [MailMessage]
        let overrides: [UUID: ProviderMessageOverride]
        let rules: [SenderRule]
        let screening: Bool
    }

    private var mergeInputs: MergeInputs {
        MergeInputs(messages: messages, overrides: providerOverrides, rules: senderRules, screening: senderScreeningEnabled)
    }

    /// A page can finish while the user is editing a message or a sender rule. Commit only against the snapshot we merged.
    func mergeReceivedPage(_ incoming: [MailMessage], deletedIDs: Set<UUID> = [], read: ProviderPageRead,
                           isCurrent: () -> Bool, beforeSave: (() -> Void)? = nil) async -> Bool {
        if incoming.isEmpty && deletedIDs.isEmpty {
            guard !Task.isCancelled, isCurrent() else { return false }
            beforeSave?()
            return true
        }
        // Opening mail only updates its read flag and cached envelope. Replay those small edits
        // on the prepared result so browsing rapidly can't indefinitely restart a page merge.
        let mergeID = UUID()
        var readerChanges: [ReaderMailChange] = []
        pendingMergeReaders[mergeID] = { readerChanges.append($0) }
        defer { pendingMergeReaders[mergeID] = nil }
        while !Task.isCancelled && isCurrent() {
            readerChanges.removeAll(keepingCapacity: true)
            let revision = mailboxDataRevision
            let inputs = mergeInputs
            let newerLabels = read.newerLabels
            var result = await prepareMerge(incoming, into: inputs, deletedIDs: deletedIDs,
                                            account: read.account, keepingLabelsFor: newerLabels)
            let offsets = readerChanges.isEmpty ? [:] : await mergedPositions(result.messages)
            guard !Task.isCancelled, isCurrent() else { return false }
            guard revision &+ readerChanges.count == mailboxDataRevision, newerLabels == read.newerLabels,
                  inputs.screening == senderScreeningEnabled, inputs.rules == senderRules else { continue }
            var expectedOverrides = inputs.overrides
            for change in readerChanges {
                switch change {
                case .read(let id):
                    expectedOverrides[id] = providerOverrides[id]
                    guard let index = offsets[id], !result.messages[index].isDeletedOnProvider else { continue }
                    result.messages[index].isUnread = false
                    var pending = result.overrides[id] ?? ProviderMessageOverride()
                    pending.isUnread = providerOverrides[id]?.isUnread
                    result.overrides[id] = pending.isEmpty ? nil : pending
                case .envelope(let id, let details):
                    if let index = offsets[id] { result.messages[index].envelopeDetails = details }
                }
            }
            guard expectedOverrides == providerOverrides else { continue }
            for earlier in activeProviderPages.prefix(while: { $0 !== read }) where earlier.account == read.account {
                earlier.newerLabels.formUnion(incoming.compactMap(\.backendMessageID))
            }
            if let beforeSave {
                persistenceSuspended += 1
                installMerge(result, processDates: !incoming.isEmpty)
                beforeSave()
                persistenceSuspended -= 1
            } else {
                installMerge(result, processDates: !incoming.isEmpty)
            }
            return true
        }
        return false
    }

    private typealias MergeResult = (messages: [MailMessage], overrides: [UUID: ProviderMessageOverride])

    @concurrent private func mergedPositions(_ messages: [MailMessage]) async -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: messages.indices.map { (messages[$0].id, $0) })
    }

    @concurrent private func prepareMerge(_ incoming: [MailMessage], into inputs: MergeInputs,
                                          deletedIDs: Set<UUID>, account: String, keepingLabelsFor newerLabels: Set<UUID>) async -> MergeResult {
        var result = merge(incoming, into: inputs, keepingLabelsFor: newerLabels)
        if !deletedIDs.isEmpty {
            for index in result.messages.indices where result.messages[index].account == account {
                if let id = result.messages[index].backendMessageID, deletedIDs.contains(id) {
                    result.messages[index].isDeletedOnProvider = true
                    result.overrides[result.messages[index].id] = nil
                }
            }
        }
        return result
    }

    private nonisolated func merge(_ incoming: [MailMessage], into inputs: MergeInputs, keepingLabelsFor newerLabels: Set<UUID> = []) -> MergeResult {
        var combined = inputs.messages
        var overrides = inputs.overrides
        guard !incoming.isEmpty else { return (combined, overrides) }
        for var message in incoming {
            if message.providerMessageID != nil { message.providerDeletedAt = nil }
            let existingIndex = combined.firstIndex {
                ($0.id == message.id
                    || (message.providerMessageID != nil && $0.providerMessageID == message.providerMessageID)
                    || (message.rfcMessageID != nil && $0.rfcMessageID == message.rfcMessageID)) && sameMailAccount($0, message)
            }
            if let existingIndex {
                let previous = combined[existingIndex]
                if let backendID = message.backendMessageID, newerLabels.contains(backendID) {
                    message.providerLabelIDs = previous.providerLabelIDs
                }
                message.id = previous.id
                message.conversationID = previous.conversationID
                message.workflow = previous.workflow
                message.backendOutboxID = previous.backendOutboxID
                message.trackOpens = previous.trackOpens
                message.trackLinks = previous.trackLinks
                if var pending = overrides[message.id] {
                    pending.apply(to: &message)
                    overrides[message.id] = pending.isEmpty ? nil : pending
                }
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
                    (($0.providerThreadID != nil && $0.providerThreadID == message.providerThreadID)
                        || $0.conversationID == message.conversationID) && sameMailAccount($0, message)
                }) {
                    message.conversationID = context.conversationID
                    message.workflow = context.workflow
                }
                if !message.isOutgoing {
                    if let rule = inputs.rules.first(where: { matchesRule($0, message: message) }) { applyRule(rule, to: &message) }
                    else if inputs.screening { message.workflow.screeningState = .pending }
                }
                combined.append(message)
            }
        }
        return (combined.sorted { $0.sentAt > $1.sentAt }, overrides)
    }

    private func installMerge(_ result: MergeResult, processDates: Bool) {
        providerOverrides = result.overrides
        suppressRemoteMutations = true
        messages = result.messages
        suppressRemoteMutations = false
        if processDates { processWorkflowDates() }
        reconcileSelection()
    }


}

enum ReaderMailChange {
    case read(UUID)
    case envelope(UUID, MailEnvelopeDetails)
}

private enum BackendQueueError {
    static let disconnected = "Connect to your Postmere workspace to manage this send."
}
