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
        let accounts = searchableAccounts
        if let scan = workflowDateScan, scan.revision == mailboxDataRevision, scan.visibleAccounts == accounts,
           scan.nextWake.map({ $0 > now }) ?? true { return }
        var updated = messages
        var changed = false
        var nextWake: Date?
        var dueConversations: Set<String> = []
        for index in updated.indices {
            guard updated[index].workflow.snoozedUntil != nil || updated[index].workflow.followUpAt != nil else { continue }
            guard accounts.contains(updated[index].account), !updated[index].isDeletedOnProvider, updated[index].mailbox != .junk else { continue }
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
            } else if let wake = updated[index].workflow.snoozedUntil {
                nextWake = min(nextWake ?? wake, wake)
            }
            let message = updated[index]
            if message.workflow.followUpAt != nil && message.workflow.followUpOnlyIfNoReply,
               let reference = message.workflow.followUpReferenceDate,
               messages.contains(where: {
                   $0.conversationID == message.conversationID && sameMailAccount($0, message)
                   && !$0.isOutgoing && !$0.isDraft && $0.mailbox != .junk && $0.sentAt > reference
               }) {
                updated[index].workflow.followUpAt = nil
                updated[index].workflow.followUpReferenceDate = nil
                changed = true
            }
        }
        if changed { messages = updated; reconcileSelection() }
        workflowDateScan = (mailboxDataRevision, accounts, nextWake)
    }

    func mergeIncoming(_ incoming: [MailMessage]) {
        guard !incoming.isEmpty else { return }
        installMerge(merge(incoming, into: mergeInputs), processDates: true)
    }

    private struct MergeInputs: Sendable {
        let messages: [MailMessage]
        let overrides: [UUID: ProviderMessageOverride]
        let selectedIDs: Set<UUID>
        let rules: [SenderRule]
        let screening: Bool
    }

    private var mergeInputs: MergeInputs {
        MergeInputs(messages: messages, overrides: providerOverrides, selectedIDs: selectedMessageIDs,
                    rules: senderRules, screening: senderScreeningEnabled)
    }

    /// A page can finish while the user is editing a message or a sender rule. Commit only against the snapshot we merged.
    func mergeReceivedPage(_ incoming: [MailMessage], deletedIDs: Set<UUID> = [], read: ProviderPageRead,
                           trackInsertions: Bool = false, isCurrent: () -> Bool,
                           beforeSave: ((_ messagesChanged: Bool, _ insertions: [(id: UUID, index: Int)]) -> Void)? = nil) async -> Bool {
        if incoming.isEmpty && deletedIDs.isEmpty {
            guard !Task.isCancelled, isCurrent() else { return false }
            beforeSave?(false, [])
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
                                            account: read.account, keepingLabelsFor: newerLabels, trackInsertions: trackInsertions)
            let offsets = readerChanges.isEmpty ? [:] : await mergedPositions(result.messages)
            guard !Task.isCancelled, isCurrent() else { return false }
            let membershipRevisions = readerChanges.count {
                if case .senderMark = $0 { return false }
                return true
            }
            guard revision &+ membershipRevisions == mailboxDataRevision, newerLabels == read.newerLabels,
                  inputs.screening == senderScreeningEnabled, inputs.rules == senderRules else { continue }
            var expectedOverrides = inputs.overrides
            for change in readerChanges {
                switch change {
                case .read(let id):
                    expectedOverrides[id] = providerOverrides[id]
                    let owner = result.replacedIDs[id] ?? id
                    guard let index = offsets[owner], !result.messages[index].isDeletedOnProvider else { continue }
                    result.messages[index].isUnread = false
                    var pending = result.overrides[owner] ?? ProviderMessageOverride()
                    pending.isUnread = providerOverrides[id]?.isUnread
                    result.overrides[owner] = pending.isEmpty ? nil : pending
                case .senderMark(let id, let mark):
                    if let index = offsets[result.replacedIDs[id] ?? id], mark.matches(result.messages[index]) {
                        result.messages[index].verifiedSenderMark = mark
                    }
                case .envelope(let id, let details):
                    if let index = offsets[result.replacedIDs[id] ?? id] { result.messages[index].envelopeDetails = details }
                }
            }
            guard expectedOverrides == providerOverrides else { continue }
            for earlier in activeProviderPages.prefix(while: { $0 !== read }) where earlier.account == read.account {
                earlier.newerLabels.formUnion(incoming.compactMap(\.backendMessageID))
            }
            if let beforeSave {
                persistenceSuspended += 1
                installMerge(result, processDates: !incoming.isEmpty)
                beforeSave(result.messagesChanged, result.insertions)
                persistenceSuspended -= 1
            } else {
                installMerge(result, processDates: !incoming.isEmpty)
            }
            return true
        }
        return false
    }

    private typealias MergeResult = (messages: [MailMessage], overrides: [UUID: ProviderMessageOverride],
                                     replacedIDs: [UUID: UUID], messagesChanged: Bool, insertions: [(id: UUID, index: Int)])

    @concurrent private func mergedPositions(_ messages: [MailMessage]) async -> [UUID: Int] {
        Dictionary(messages.indices.map { (messages[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @concurrent private func prepareMerge(_ incoming: [MailMessage], into inputs: MergeInputs,
                                          deletedIDs: Set<UUID>, account: String, keepingLabelsFor newerLabels: Set<UUID>,
                                          trackInsertions: Bool) async -> MergeResult {
        var result = merge(incoming, into: inputs, keepingLabelsFor: newerLabels, trackInsertions: trackInsertions)
        if !deletedIDs.isEmpty {
            var affected = Set<UUID>()
            for index in result.messages.indices where result.messages[index].account == account {
                if let id = result.messages[index].backendMessageID, deletedIDs.contains(id) {
                    if !result.messages[index].isDeletedOnProvider {
                        affected.insert(result.messages[index].conversationID)
                        result.messages[index].isDeletedOnProvider = true
                        result.messagesChanged = true
                    }
                    result.overrides[result.messages[index].id] = nil
                }
            }
            if !affected.isEmpty { MailReplyQueue.reconcile(&result.messages, conversations: affected) }
        }
        return result
    }

    private nonisolated func merge(_ incoming: [MailMessage], into inputs: MergeInputs, keepingLabelsFor newerLabels: Set<UUID> = [],
                                   trackInsertions: Bool = false) -> MergeResult {
        var combined = inputs.messages
        var overrides = inputs.overrides
        var replacedIDs: [UUID: UUID] = [:]
        guard !incoming.isEmpty else { return (combined, overrides, replacedIDs, false, []) }
        var insertedIDs: Set<UUID> = []
        var messagesChanged = false
        var needsSort = false
        var positions = MailMergePositions(combined)
        var replyThreads = Set<UUID>()
        for var message in incoming {
            message.replyRequestCandidates = MailReplyIntent.candidates(in: message)
            message.replyRequestText = nil
            if message.providerMessageID != nil { message.providerDeletedAt = nil }
            var matches = positions.matches(message)
            if message.backendMessageID != nil, let queuedID = message.postmereSendID,
               let index = positions.local(queuedID, in: message),
               combined[index].backendMessageID == nil, combined[index].isOutgoing,
               combined[index].providerMessageID?.isEmpty != false || combined[index].providerMessageID == message.providerMessageID,
               combined[index].mailbox == .outbox || combined[index].mailbox == .sent,
               combined[index].postmereSendID == queuedID {
                matches.insert(index)
            }
            var existingIndex = matches.min()
            if matches.count > 1, message.account.hasPrefix("remote:") {
                messagesChanged = true
                needsSort = true
                let indices = matches.sorted()
                let copies = indices.map { combined[$0] }
                let survivor = MailSyncRepair.mergeCopies(copies, preferring: inputs.selectedIDs)
                if !insertedIDs.isEmpty {
                    let allNew = copies.allSatisfy { insertedIDs.contains($0.id) }
                    insertedIDs.subtract(copies.map(\.id))
                    if allNew { insertedIDs.insert(survivor.id) }
                }
                for copy in copies where copy.id != survivor.id {
                    for (id, owner) in replacedIDs where owner == copy.id { replacedIDs[id] = survivor.id }
                    replacedIDs[copy.id] = survivor.id
                    if let pending = overrides.removeValue(forKey: copy.id) {
                        var kept = overrides[survivor.id] ?? ProviderMessageOverride()
                        kept.isUnread = kept.isUnread ?? pending.isUnread
                        kept.isStarred = kept.isStarred ?? pending.isStarred
                        kept.mailbox = kept.mailbox ?? pending.mailbox
                        overrides[survivor.id] = kept
                    }
                }
                let slot = indices[0]
                for index in indices.dropFirst().reversed() { combined.remove(at: index) }
                combined[slot] = survivor
                positions = MailMergePositions(combined)
                existingIndex = slot
            }
            if let existingIndex {
                let previous = combined[existingIndex]
                if let backendID = message.backendMessageID, newerLabels.contains(backendID) {
                    message.providerLabelIDs = previous.providerLabelIDs
                    message.providerCategories = previous.providerCategories
                }
                message.id = previous.id
                message.conversationID = previous.conversationID
                message.workflow = previous.workflow
                if message.replyRequestCandidates == previous.replyRequestCandidates {
                    message.replyRequestText = previous.replyRequestText
                }
                message.automaticReplyPending = previous.automaticReplyPending
                message.triagePriority = message.triagePriority ?? previous.triagePriority
                message.backendMessageID = message.backendMessageID ?? previous.backendMessageID
                if message.providerMessageID?.isEmpty != false { message.providerMessageID = previous.providerMessageID }
                message.providerThreadID = message.providerThreadID ?? previous.providerThreadID
                message.rfcMessageID = message.rfcMessageID ?? previous.rfcMessageID
                message.backendOutboxID = previous.backendOutboxID ?? message.backendOutboxID
                message.envelopeDetails = message.envelopeDetails ?? previous.envelopeDetails
                if message.verifiedSenderMark == nil, let mark = previous.currentSenderMark,
                   mark.matches(message) {
                    message.verifiedSenderMark = mark
                }
                message.trackOpens = previous.trackOpens
                message.trackLinks = previous.trackLinks
                if var pending = overrides[message.id] {
                    pending.apply(to: &message)
                    overrides[message.id] = pending.isEmpty ? nil : pending
                }
                if message.mailbox == .trash, previous.mailbox == .trash {
                    message.trashedFrom = previous.trashedFrom
                }
                message.retainDownloads(from: previous)
                if previous.mailbox == .outbox {
                    guard message.backendMessageID != nil else { continue }
                    // Cache sync may see Sent before the outbox poll does. Keep
                    // queue state, but retain the identifiers before its cursor
                    // advances past this message permanently.
                    var queued = previous
                    queued.backendMessageID = message.backendMessageID
                    queued.providerMessageID = message.providerMessageID
                    queued.providerThreadID = message.providerThreadID
                    queued.rfcMessageID = message.rfcMessageID
                    message = queued
                }
                if message != previous {
                    replyThreads.insert(message.conversationID)
                    messagesChanged = true
                    if previous.sentAt != message.sentAt { needsSort = true }
                    combined[existingIndex] = message
                    positions.replace(previous, with: message, at: existingIndex)
                }
            } else {
                if let context = combined.first(where: {
                    (($0.providerThreadID != nil && $0.providerThreadID == message.providerThreadID)
                        || $0.conversationID == message.conversationID) && sameMailAccount($0, message)
                        && ($0.mailbox == .junk) == (message.mailbox == .junk)
                }) {
                    message.conversationID = context.conversationID
                    message.workflow = context.workflow
                }
                if !message.isOutgoing && message.mailbox != .junk {
                    if let rule = SenderRule.first(in: inputs.rules, where: { matchesRule($0, message: message) }) { applyRule(rule, to: &message) }
                    else if inputs.screening { message.workflow.screeningState = .pending }
                }
                messagesChanged = true
                needsSort = true
                replyThreads.insert(message.conversationID)
                positions.insert(message, at: combined.count)
                combined.append(message)
                if trackInsertions { insertedIDs.insert(message.id) }
            }
        }
        if !replyThreads.isEmpty { MailReplyQueue.reconcile(&combined, conversations: replyThreads) }
        if needsSort { combined.sort { $0.sentAt > $1.sentAt } }
        let insertions = insertedIDs.isEmpty ? [] : combined.indices.compactMap { index -> (UUID, Int)? in
            let id = combined[index].id
            return insertedIDs.contains(id) ? (id, index) : nil
        }
        return (combined, overrides, replacedIDs, messagesChanged, insertions)
    }

    private func installMerge(_ result: MergeResult, processDates: Bool) {
        if providerOverrides != result.overrides { providerOverrides = result.overrides }
        // A replay can acknowledge an optimistic flag without changing any displayed message.
        guard result.messagesChanged else { return }
        let wasSuppressing = suppressRemoteMutations
        suppressRemoteMutations = true
        messages = result.messages
        suppressRemoteMutations = wasSuppressing
        if !result.replacedIDs.isEmpty {
            isUpdatingSelection = true
            if let id = selectedMessageID, let owner = result.replacedIDs[id] { selectedMessageID = owner }
            selectedMessageIDs = Set(selectedMessageIDs.map { result.replacedIDs[$0] ?? $0 })
            isUpdatingSelection = false
        }
        if processDates { processWorkflowDates() }
        reconcileSelection()
    }


}

enum ReaderMailChange {
    case read(UUID)
    case envelope(UUID, MailEnvelopeDetails)
    case senderMark(UUID, MailVerifiedSenderMark)
}

private enum BackendQueueError {
    static let disconnected = "Connect to your Postmere workspace to manage this send."
}
