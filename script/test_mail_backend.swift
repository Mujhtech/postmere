import Foundation

enum RegressionFailure: Error { case failed(String) }

@main struct PostmereBackendRegression {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw RegressionFailure.failed(description) }
        print("PASS \(description)")
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PostmereRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runSearchSplitRegressions(directory: directory)
        try await runRemoteMailRegressions(directory: directory)
        let stateURL = directory.appendingPathComponent("state.json")
        let initial = MailMessage(sender: "Pat", senderEmail: "pat@example.com", initials: "P", subject: "A question", preview: "Hello", paragraphs: ["Hello"], timeLabel: "10:00", isUnread: true, sentAt: .now.addingTimeInterval(-100))
        let store = MailStore(messages: [initial], persistenceURL: stateURL)
        store.setNeedsReply(true, for: initial.id)
        store.setPrivateNote("Do not send this private note", for: initial.id)
        store.snoozeMessage(initial.id, until: .now.addingTimeInterval(100))
        store.saveSnippet(MailSnippet(title: "Thanks", body: "Thank you, {{name}}."))
        let criteria = SavedInboxCriteria(query: "question", attachmentsOnly: false, sender: "pat", domain: "example.com", mailbox: nil)
        store.saveInboxView(name: "Pat", criteria: criteria)
        let reopened = MailStore(messages: [], persistenceURL: stateURL)
        try check(reopened.messages.first?.workflow.privateNote == "Do not send this private note", "private workflow metadata survives restart")
        try check(reopened.count(for: .snoozed) == 1 && reopened.count(for: .inbox) == 0, "snooze hides inbox mail durably")
        try check(reopened.snippets.count == 1 && reopened.savedViews.count == 1, "snippets and saved views survive restart")
        reopened.processWorkflowDates(now: .now.addingTimeInterval(200))
        try check(reopened.count(for: .snoozed) == 0 && reopened.count(for: .needsReply) == 1, "due snooze restores an unread actionable conversation")
        reopened.selectSavedView(reopened.savedViews[0])
        try check(reopened.filteredMessages.count == 1, "saved sender/domain/query view selects matching mail")

        reopened.setFollowUp(initial.id, at: .now.addingTimeInterval(100), onlyIfNoReply: true)
        let incoming = MailMessage(sender: "Pat", senderEmail: "pat@example.com", initials: "P", subject: "Re: A question", preview: "Answer", paragraphs: ["Answer"], timeLabel: "Now", conversationID: initial.conversationID, sentAt: .now.addingTimeInterval(1))
        reopened.mergeIncoming([incoming])
        try check(reopened.messages.allSatisfy { $0.workflow.followUpAt == nil }, "a later received reply cancels a no-reply reminder across the conversation")
        try check(reopened.messages.allSatisfy { $0.workflow.privateNote == "Do not send this private note" }, "new replies inherit private conversation context")

        reopened.senderScreeningEnabled = true
        let stranger = MailMessage(sender: "New sender", senderEmail: "new@example.com", initials: "N", subject: "New", preview: "Hi", paragraphs: ["Hi"], timeLabel: "Now")
        reopened.mergeIncoming([stranger])
        try check(reopened.count(for: .newSenders) == 1, "unknown senders enter screening")
        reopened.acceptSender(of: stranger, route: .archive)
        try check(reopened.messages.first(where: { $0.id == stranger.id })?.mailbox == .archive && reopened.count(for: .newSenders) == 0, "accepting sender applies routing")

        let attachment = directory.appendingPathComponent("example.txt")
        try Data("persistent attachment".utf8).write(to: attachment)
        let bounded = try MailAttachment.boundedFileData(at: attachment, maximumBytes: 21)
        try check(bounded == Data("persistent attachment".utf8), "bounded upload reads preserve exact file bytes at the limit")
        let rejectedUpload = try? MailAttachment.boundedFileData(at: attachment, maximumBytes: 1)
        try check(rejectedUpload == nil, "upload byte limits reject oversized files before loading them")
        reopened.beginCompose()
        reopened.draftTo = "person@example.com"
        reopened.draftSubject = "Recover me"
        reopened.draftBody = "A recoverable body"
        reopened.draftBodyRTF = Data("rich text bytes".utf8)
        try reopened.addDraftAttachments(from: [attachment])
        try FileManager.default.removeItem(at: attachment)
        let recovered = MailStore(messages: [], persistenceURL: stateURL)
        try check(recovered.draftRecoveryAvailable, "active composer is recoverable after restart")
        recovered.recoverDraft()
        try check(recovered.draftBody == "A recoverable body" && recovered.draftBodyRTF == Data("rich text bytes".utf8), "draft text and rich representation recover")
        try check(recovered.draftAttachments.first?.localURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "attachment remains after original file is deleted")
        recovered.sendDraft()
        try check(!recovered.isComposing && recovered.outgoingQueue.count == 1, "send atomically queues before closing compose")
        let queuedRestart = MailStore(messages: [], persistenceURL: stateURL)
        try check(!queuedRestart.draftRecoveryAvailable && queuedRestart.outgoingQueue.count == 1, "outgoing queue survives restart without phantom active draft")
        queuedRestart.undoLastSend()
        try check(queuedRestart.outgoingQueue.isEmpty && queuedRestart.isComposing && queuedRestart.draftSubject == "Recover me", "undo send restores editable message")
        queuedRestart.draftSendAt = .now.addingTimeInterval(600)
        queuedRestart.sendDraft()
        let scheduled = queuedRestart.outgoingQueue[0]
        await queuedRestart.processDueWork(now: scheduled.scheduledAt.addingTimeInterval(-1))
        try check(queuedRestart.outgoingQueue.count == 1, "scheduled mail does not deliver early")
        await queuedRestart.processDueWork(now: scheduled.scheduledAt.addingTimeInterval(1))
        try check(queuedRestart.outgoingQueue.isEmpty && queuedRestart.messages.contains { $0.id == scheduled.id && $0.mailbox == .sent }, "due sample mail moves to Sent once")
        let deliveredRestart = MailStore(messages: [], persistenceURL: stateURL)
        try check(deliveredRestart.outgoingQueue.isEmpty && deliveredRestart.messages.contains { $0.id == scheduled.id && $0.mailbox == .sent }, "delivery completion survives restart")

        let scheduledDraftURL = directory.appendingPathComponent("scheduled-draft.json")
        let scheduledDraft = MailStore(messages: [], persistenceURL: scheduledDraftURL)
        scheduledDraft.beginCompose()
        scheduledDraft.draftTo = "recipient@example.com"
        scheduledDraft.draftSubject = "Save this schedule"
        let plannedSend = Date.now.addingTimeInterval(3_600)
        scheduledDraft.draftSendAt = plannedSend
        scheduledDraft.saveDraft()
        let savedScheduleRestart = MailStore(messages: [], persistenceURL: scheduledDraftURL)
        savedScheduleRestart.beginEditingDraft(savedScheduleRestart.messages[0])
        try check(abs(savedScheduleRestart.draftSendAt!.timeIntervalSince(plannedSend)) < 0.001, "explicit saved draft retains its scheduled-send date across restart")
        savedScheduleRestart.sendDraft()
        try check(abs(savedScheduleRestart.outgoingQueue[0].scheduledAt.timeIntervalSince(plannedSend)) < 0.001, "reopened scheduled draft queues for the intended future time")
        await savedScheduleRestart.processDueWork(now: plannedSend.addingTimeInterval(1))
        try check(savedScheduleRestart.messages[0].workflow.scheduledSendAt == nil, "sent message clears draft-only send schedule")

        let live = MailStore(messages: [])
        live.beginCompose()
        live.draftAccount = .gmail
        live.draftTo = "person@example.com"
        live.draftSubject = "Live failure"
        live.sendDraft()
        let liveID = live.outgoingQueue[0].id
        await live.processDueWork(now: live.outgoingQueue[0].scheduledAt.addingTimeInterval(1))
        try check(live.outgoingQueue[0].status == .failed && live.messages.first?.mailbox == .outbox, "unconnected Gmail never pretends to send")
        live.liveSender = { message in var sent = message; sent.providerMessageID = "live-123"; return sent }
        live.retrySend(liveID)
        await live.processDueWork(now: .now.addingTimeInterval(1))
        try check(live.outgoingQueue.isEmpty && live.messages.first?.providerMessageID == "live-123", "injected live delivery preserves provider receipt")

        live.remoteMutation = { _, _ in throw RegressionFailure.failed("provider offline") }
        live.toggleStar(liveID)
        for task in live.remoteMutationTasks.values { await task.value }
        try check(live.messages.first?.isStarred == false && live.operationError != nil, "failed provider mutation rolls back local state with visible error")

        let brokenURL = directory.appendingPathComponent("broken.json")
        let broken = Data("not valid JSON".utf8)
        try broken.write(to: brokenURL)
        let corruptStore = MailStore(messages: [], persistenceURL: brokenURL)
        corruptStore.saveSnippet(MailSnippet(title: "Prevent overwrite", body: "hello"))
        try check(corruptStore.persistenceError != nil && !corruptStore.flushPersistence(), "corrupt mailbox is reported and writes are blocked")
        let unchanged = try Data(contentsOf: brokenURL)
        try check(unchanged == broken, "corrupt source is never overwritten by fresh data")

        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedDirectory)
        let failedSave = MailStore(messages: [], persistenceURL: blockedDirectory.appendingPathComponent("state.json"))
        failedSave.beginCompose()
        failedSave.draftTo = "recipient@example.com"
        failedSave.draftSubject = "Keep my draft"
        failedSave.sendDraft()
        try check(failedSave.isComposing && failedSave.outgoingQueue.isEmpty && failedSave.draftSubject == "Keep my draft", "failed queue persistence keeps composer and text intact")
        failedSave.saveDraft()
        failedSave.saveDraft()
        try check(failedSave.isComposing && failedSave.messages.isEmpty, "failed draft saves do not close composer or create duplicate messages")

        let other = MailMessage(sender: "Another", senderEmail: "another@example.com", initials: "A", subject: "Other", preview: "Other", paragraphs: ["Other"], timeLabel: "Now")
        let batch = MailStore(messages: [initial, other])
        batch.setSelection([initial.id, other.id])
        try check(batch.selectedMessages.count == 2 && batch.selectedMessageID != nil, "native multi-selection retains a reader lead")
        batch.moveMessages(batch.selectedMessageIDs, to: .archive)
        try check(batch.messages.allSatisfy { $0.mailbox == .archive }, "batch archive moves all selected mail")
        batch.undoLastMove()
        try check(batch.messages.allSatisfy { $0.mailbox == .inbox } && batch.selectedMessageIDs.count == 2, "batch undo restores all moved messages and selection")
        batch.archiveSelected()
        try check(batch.messages.allSatisfy { $0.mailbox == .archive }, "reader and menu archive helper respects the complete selection")
        batch.undoLastMove()
        batch.deleteSelected()
        try check(batch.messages.allSatisfy { $0.mailbox == .trash }, "reader and menu trash helper respects the complete selection")
        batch.selectMailbox(.trash)
        batch.setSelection([initial.id, other.id])
        try check(batch.restoreSelected() && batch.messages.allSatisfy { $0.mailbox == .inbox }, "restore helper restores every selected trashed message")
        batch.undoLastMove()
        try check(batch.messages.allSatisfy { $0.mailbox == .trash }, "one undo reverses a batch restore")
        var trashedDraft = other
        trashedDraft.id = UUID()
        trashedDraft.mailbox = .trash
        trashedDraft.trashedFrom = .drafts
        var trashedArchive = initial
        trashedArchive.mailbox = .trash
        trashedArchive.trashedFrom = .archive
        let mixedRestore = MailStore(messages: [trashedDraft, trashedArchive])
        mixedRestore.selectMailbox(.trash)
        mixedRestore.setSelection([trashedDraft.id, trashedArchive.id])
        mixedRestore.restoreSelected()
        try check(mixedRestore.messages.contains { $0.id == trashedDraft.id && $0.mailbox == .drafts }
                  && mixedRestore.messages.contains { $0.id == trashedArchive.id && $0.mailbox == .archive },
                  "batch restore respects each message’s original destination")

        let interruptedURL = directory.appendingPathComponent("interrupted.json")
        let interrupted = MailStore(messages: [], persistenceURL: interruptedURL)
        interrupted.beginCompose()
        interrupted.draftTo = "recipient@example.com"
        interrupted.draftSubject = "Interrupted"
        interrupted.sendDraft()
        interrupted.outgoingQueue[0].status = .delivering
        let interruptedRestart = MailStore(messages: [], persistenceURL: interruptedURL)
        try check(interruptedRestart.outgoingQueue[0].status == .failed && interruptedRestart.outgoingQueue[0].lastError?.contains("Check Sent") == true, "interrupted live sends require inspection before retry")

        let third = MailMessage(sender: "Pat", senderEmail: "pat@example.com", initials: "P", subject: "Re: A question", preview: "Third", paragraphs: ["Third"], timeLabel: "Now", conversationID: initial.conversationID, sentAt: .now.addingTimeInterval(2))
        let conversation = MailStore(messages: [initial, incoming, third])
        conversation.setNeedsReply(true, for: initial.id)
        conversation.selectMailbox(.needsReply)
        try check(conversation.count(for: .needsReply) == 1 && conversation.filteredMessages.count == 1, "three-message conversation creates one workflow task and badge")
        var snoozeEvents = 0
        conversation.onSnoozeDue = { _, _ in snoozeEvents += 1 }
        conversation.snoozeMessage(initial.id, until: .now.addingTimeInterval(5))
        conversation.processWorkflowDates(now: .now.addingTimeInterval(6))
        conversation.processWorkflowDates(now: .now.addingTimeInterval(7))
        try check(snoozeEvents == 1, "snooze wake emits one notification event per conversation")

        live.remoteMutation = { _, _ in }
        live.toggleStar(liveID)
        for task in live.remoteMutationTasks.values { await task.value }
        var stale = live.messages[0]
        stale.isStarred = false
        live.mergeIncoming([stale])
        try check(live.messages[0].isStarred, "stale sync cannot overwrite a fresh local provider action")
        stale.isStarred = true
        live.mergeIncoming([stale])
        stale.isStarred = false
        live.mergeIncoming([stale])
        try check(!live.messages[0].isStarred, "confirmed provider state later accepts external changes")

        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        var preferences = originalArguments
        preferences["gmailEmail"] = "old@example.com"
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        let identityQueue = MailStore(messages: [])
        identityQueue.beginCompose()
        identityQueue.draftAccount = .gmail
        identityQueue.draftTo = "recipient@example.com"
        identityQueue.draftSubject = "Original account"
        identityQueue.sendDraft()
        let capturedIdentity = identityQueue.messages[0].providerAccountEmail
        let identityDraft = MailStore(messages: [])
        identityDraft.beginCompose()
        identityDraft.draftAccount = .gmail
        identityDraft.draftTo = "recipient@example.com"
        identityDraft.draftSubject = "Do not switch sender"
        preferences["gmailEmail"] = "new@example.com"
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        var calledSender = false
        identityQueue.liveSender = { message in calledSender = true; return message }
        await identityQueue.processDueWork(now: identityQueue.outgoingQueue[0].scheduledAt.addingTimeInterval(1))
        try check(capturedIdentity == "old@example.com" && !calledSender && identityQueue.outgoingQueue[0].status == .failed, "Gmail account switch cannot deliver another account’s queued mail")
        try check(!identityDraft.canSendDraft, "Gmail draft retains original sender and blocks mismatched account")
        var oldAccount = initial
        oldAccount.account = MailAccount.gmail.rawValue
        oldAccount.providerAccountEmail = "old@example.com"
        oldAccount.providerMessageID = "same-provider-id"
        oldAccount.rfcMessageID = "same-message-id"
        var newAccount = oldAccount
        newAccount.id = UUID()
        newAccount.providerAccountEmail = "new@example.com"
        let identities = MailStore(messages: [oldAccount])
        identities.setPrivateNote("Old account note", for: oldAccount.id)
        identities.mergeIncoming([newAccount])
        try check(identities.messages.count == 2 && identities.filteredMessages.count == 1 && identities.filteredMessages[0].id == newAccount.id, "account switch hides cached mail without merging or deleting it")
        try check(identities.filteredMessages[0].workflow.privateNote.isEmpty, "private notes do not leak between provider identities")
        identities.setPrivateNote("Keep this deleted email’s context", for: newAccount.id)
        identities.setFollowUp(newAccount.id, at: .now.addingTimeInterval(60))
        identities.markProviderMessagesUnavailable(ids: ["same-provider-id"], accountEmail: "new@example.com")
        try check(identities.messages.count == 2 && identities.filteredMessages.isEmpty && identities.notificationSchedules.isEmpty, "verified remote deletion hides original without deleting retained data or scheduling reminders")
        try check(identities.messages.first(where: { $0.id == newAccount.id })?.workflow.privateNote == "Keep this deleted email’s context"
                  && identities.messages.first(where: { $0.id == oldAccount.id })?.isDeletedOnProvider == false,
                  "remote deletion retains private notes and affects only the verified provider identity")
        identities.mergeIncoming([newAccount])
        try check(identities.filteredMessages.count == 1 && !identities.filteredMessages[0].isDeletedOnProvider,
                  "a later successful provider read restores hidden mail")
        var retainedDraft = newAccount
        retainedDraft.id = UUID()
        retainedDraft.mailbox = .drafts
        retainedDraft.providerMessageID = "deleted-draft"
        let draftDeletion = MailStore(messages: [retainedDraft])
        draftDeletion.markProviderMessagesUnavailable(ids: ["deleted-draft"], accountEmail: "new@example.com")
        draftDeletion.selectMailbox(.drafts)
        try check(draftDeletion.filteredMessages.count == 1 && draftDeletion.messages[0].isDeletedOnProvider,
                  "provider deletion never hides or removes local saved drafts")
        print("All backend regressions passed")
    }
}
