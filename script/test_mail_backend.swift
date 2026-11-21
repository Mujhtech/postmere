import Foundation

enum RegressionFailure: Error { case failed(String) }

@main struct PostmereBackendRegression {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw RegressionFailure.failed(description) }
        print("PASS \(description)")
    }

    /// Bodies live in their own files: the snapshot stays small, unchanged bodies
    /// are not rewritten, removed messages lose their body file, and format 1
    /// snapshots (bodies inline) still open.
    @MainActor static func separateBodyStorage(directory: URL) throws {
        let file = directory.appendingPathComponent("bodies.json")
        let persistence = MailPersistence(fileURL: file)
        let html = "<p>" + String(repeating: "Long body ", count: 2_000) + "</p>"
        var first = MailMessage(sender: "Pat", senderEmail: "pat@example.org", initials: "P", subject: "One",
                                preview: "Example", paragraphs: ["Plain body text"], timeLabel: "9:00", isUnread: true)
        first.bodyHTML = html
        let second = MailMessage(sender: "Lee", senderEmail: "lee@example.org", initials: "L", subject: "Two",
                                 preview: "Second", paragraphs: ["Second body"], timeLabel: "9:05", isUnread: false)
        let store = MailStore(messages: [first, second], persistenceURL: file)
        try check(store.flushPersistence(), "a mailbox with bodies saves")
        let snapshotText = try String(contentsOf: file, encoding: .utf8)
        try check(!snapshotText.contains("Long body") && !snapshotText.contains("Plain body text"),
                  "the snapshot holds metadata only; bodies are stored separately")
        let loaded = try persistence.load()
        try check(loaded?.messages.first { $0.id == first.id }?.bodyHTML == html
                  && loaded?.messages.first { $0.id == second.id }?.paragraphs == ["Second body"],
                  "bodies are restored on load")

        let bodyFile = persistence.bodyDirectory.appendingPathComponent(first.id.uuidString.lowercased() + ".json")
        let writtenAt = try FileManager.default.attributesOfItem(atPath: bodyFile.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        store.messages[0].isStarred = true
        try check(store.flushPersistence(), "a metadata change saves")
        let rewrittenAt = try FileManager.default.attributesOfItem(atPath: bodyFile.path)[.modificationDate] as? Date
        try check(writtenAt != nil && writtenAt == rewrittenAt, "an unchanged body is not rewritten")

        store.messages.removeAll { $0.id == first.id }
        try check(store.flushPersistence() && !FileManager.default.fileExists(atPath: bodyFile.path),
                  "removing a message removes its body file")

        // A format 1 snapshot keeps bodies inline and is upgraded on the next save.
        let legacyFile = directory.appendingPathComponent("format1-bodies.json")
        let legacy = MailPersistence(fileURL: legacyFile)
        var inline = try persistence.load()!
        inline.schemaVersion = 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        inline.messages[0].paragraphs = ["Inline legacy body"]
        try encoder.encode(inline).write(to: legacyFile)
        let opened = try legacy.load()
        try check(opened?.messages.first?.paragraphs == ["Inline legacy body"], "format 1 snapshots still open")
    }

    /// The mailbox opens on metadata; bodies arrive afterwards. A save made in
    /// between must keep every body file, and opening a message loads its body.
    @MainActor static func lazyBodyOpening(directory: URL) async throws {
        let file = directory.appendingPathComponent("lazy-bodies.json")
        var messages: [MailMessage] = []
        for index in 0..<650 {
            var message = MailMessage(sender: "Sender \(index)", senderEmail: "s\(index)@example.org", initials: "S",
                                      subject: "Subject \(index)", preview: "Preview \(index)",
                                      paragraphs: ["Body number \(index)"], timeLabel: "9:00", isUnread: true)
            message.sentAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            messages.append(message)
        }
        let seed = MailStore(messages: messages, persistenceURL: file)
        try check(seed.flushPersistence(), "a large mailbox saves")

        let store = MailStore(messages: [], persistenceURL: file, openInBackground: true)
        await store.openingTask?.value
        try check(!store.isOpeningMailbox && store.messages.count == 650, "the mailbox opens before its bodies are read")
        // Cancel the fill so the next save certainly runs with bodies missing.
        store.bodyFillTask?.cancel()
        store.messages[0].isStarred = true
        try check(store.flushPersistence(), "a save while bodies are missing succeeds")
        let reread = try MailPersistence(fileURL: file).load()
        try check(reread?.messages.count == 650 && reread?.messages.allSatisfy { $0.paragraphs.first?.hasPrefix("Body number") == true } == true,
                  "a save before bodies load keeps every stored body")

        let reopened = MailStore(messages: [], persistenceURL: file, openInBackground: true)
        await reopened.openingTask?.value
        let oldest = reopened.messages.min { $0.sentAt < $1.sentAt }!
        reopened.bodyFillTask?.cancel()
        reopened.select(oldest)
        try check(reopened.messages.first { $0.id == oldest.id }?.paragraphs == ["Body number 0"],
                  "opening a message before the background fill reaches it loads its body")
        let filling = MailStore(messages: [], persistenceURL: file, openInBackground: true)
        await filling.openingTask?.value
        await filling.bodyFillTask?.value
        try check(filling.messages.allSatisfy { $0.paragraphs.first?.hasPrefix("Body number") == true },
                  "the background fill restores every body")
    }

    /// Dragging rows onto sidebar mailboxes moves, stars or flags them, and a
    /// mailbox never takes mail it cannot hold.
    @MainActor static func dropOnSidebar() throws {
        var first = MailMessage(sender: "Pat", senderEmail: "pat@example.org", initials: "P", subject: "One",
                                preview: "One", paragraphs: ["One"], timeLabel: "9:00", isUnread: true)
        first.mailbox = .inbox
        var second = first
        second.id = UUID(); second.subject = "Two"
        var sent = first
        sent.id = UUID(); sent.subject = "Sent"; sent.isOutgoing = true; sent.mailbox = .sent
        let store = MailStore(messages: [first, second, sent])
        store.selectedMessageIDs = [first.id, second.id]
        try check(Set(store.draggedMessageIDs(from: first.id)) == [first.id, second.id] && store.draggedMessageIDs(from: sent.id) == [sent.id],
                  "dragging a selected row drags the whole selection; another row drags alone")
        try check(store.drop([first.id], on: .starred) && store.messages.first { $0.id == first.id }?.isStarred == true,
                  "dropping on Starred stars the message")
        try check(!store.drop([sent.id], on: .junk) && store.messages.first { $0.id == sent.id }?.mailbox == .sent,
                  "your own sent mail is not moved to Junk")
        try check(!store.drop([first.id], on: .sent) && !store.drop([first.id], on: .snoozed),
                  "mailboxes that cannot take mail refuse the drop")
        try check(store.drop([first.id, second.id], on: .archive)
                  && store.messages.filter { $0.mailbox == .archive }.count == 2, "dropping on Archive moves every dragged message")
    }

    @MainActor static func readerPersistence(directory: URL) async throws {
        let file = directory.appendingPathComponent("reader.json")
        let message = MailMessage(sender: "Pat", senderEmail: "pat@example.org", initials: "P",
                                  subject: "Reader", preview: "Example", paragraphs: ["Example"],
                                  timeLabel: "9:00", isUnread: true)
        let store = MailStore(messages: [message], persistenceURL: file)
        let saved = MailPersistence(fileURL: file)

        // Hold disk writes while opening the message and its metadata. Both must
        // update the live UI without waiting on the storage queue.
        store.saveQueue.suspend()
        store.select(message)
        store.cacheEnvelope(MailEnvelopeDetails(recipientNames: [:], signingDomains: ["example.org"]),
                            messageID: message.id, account: message.account)
        let revision = store.saveRevision
        store.select(message)
        let diskWhileReading = try? saved.load()
        store.saveQueue.resume()
        try check(store.messages.first?.isUnread == false && diskWhileReading?.messages.first?.isUnread == true,
                  "opening an unread message updates the reader independently of disk")
        try check(store.saveRevision == revision, "reopening a read message schedules no save")

        await withCheckedContinuation { continuation in
            store.saveQueue.async { continuation.resume() }
        }
        let disk = try saved.load()?.messages.first
        try check(disk?.isUnread == false && disk?.envelopeDetails?.signingDomains == ["example.org"],
                  "background save includes both read state and envelope metadata")
        store.messages[0].isStarred = true
        try check(store.flushPersistence(), "explicit flush completes after reader saves")
        let restored = try saved.load()?.messages.first
        try check(restored?.isStarred == true && restored?.isUnread == false, "newer explicit changes survive a reopen")

        let split = store.inboxSplits[1]
        store.saveQueue.suspend()
        store.selectInboxSplit(split.id)
        store.isComposing = true
        store.draftSubject = "Typing while a write is pending"
        let beforeWrite = try? saved.load()
        store.saveQueue.resume()
        try check(store.selectedInboxSplitID == split.id && beforeWrite?.selectedInboxSplitID != split.id &&
                  beforeWrite?.activeDraft == nil, "tab navigation and typing return while mailbox storage is busy")
        let savedLatest = await store.persistStateAsync()
        let afterWrite = try saved.load()
        try check(savedLatest && afterWrite?.selectedInboxSplitID == split.id &&
                  afterWrite?.activeDraft?.subject == store.draftSubject, "a durable commit includes the latest navigation and draft edits")

        store.saveQueue.suspend()
        let opening = MailStore(messages: [], persistenceURL: file, openInBackground: true)
        let showedLoading = opening.isOpeningMailbox && opening.messages.isEmpty
        store.saveQueue.resume()
        await opening.openingTask?.value
        try check(showedLoading && !opening.isOpeningMailbox && opening.messages.first?.id == message.id &&
                  opening.recoveredDraft?.subject == store.draftSubject, "the window can display loading before a delayed cache read restores the mailbox and draft")

        var legacy = message
        legacy.providerAccountEmail = nil
        var first = message
        first.id = UUID()
        first.providerAccountEmail = "A@example.org"
        var second = first
        second.id = UUID()
        second.providerAccountEmail = "b@example.org"
        var trashed = first
        trashed.id = UUID()
        trashed.mailbox = .trash
        let countsStore = MailStore(messages: [legacy, first, second, trashed])
        let indexed = countsStore.conversationCounts(for: countsStore.messages)
        try check(countsStore.messages.allSatisfy { indexed[$0.id] == countsStore.conversationCount(for: $0) },
                  "list thread counts preserve legacy account matching and trash handling")

        let reader = MailStore(messages: [first, second, trashed])
        reader.selectedMessageID = first.id
        await reader.loadMailboxView()
        try check(reader.selectedConversation.map(\.id) == [first.id],
                  "opening a single-message thread excludes other provider identities and trashed siblings")
        first.subject = "Updated after sync"
        reader.messages = [second, legacy, first, trashed]
        try check(reader.selectedMessage?.subject == first.subject &&
                  Set(reader.selectedConversation.map(\.id)) == [first.id, legacy.id],
                  "the reader resolves its new row and thread after a sync reorders messages and adds a legacy sibling")
        reader.messages.removeAll { $0.id == first.id }
        try check(reader.selectedMessage == nil && reader.selectedConversation.isEmpty,
                  "a removed selection cannot return a cached reader message")
    }

    @MainActor static func dockUnreadCounts() async throws {
        let domain = "postmere-dock-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let previousAccounts = RemoteAccountRegistry.accounts
        defer {
            defaults.removePersistentDomain(forName: domain)
            RemoteAccountRegistry.accounts = previousAccounts
        }
        let accounts = ["one", "two"].map {
            RemoteAccountIdentity(localID: "remote:fixture:\($0)", accountID: UUID(), scope: "fixture",
                                  email: "\($0)@example.com", displayName: $0, provider: "gmail")
        }
        RemoteAccountRegistry.accounts = accounts
        func message(_ account: String) -> MailMessage {
            MailMessage(sender: "Test", senderEmail: "test@example.com", initials: "T", subject: "Unread",
                        preview: "", paragraphs: [], timeLabel: "Now", isUnread: true, account: account)
        }
        let first = message(accounts[0].localID)
        let second = message(accounts[1].localID)
        var archived = message(first.account)
        archived.mailbox = .archive
        var snoozed = message(first.account)
        snoozed.workflow.snoozedUntil = .distantFuture
        var deleted = message(second.account)
        deleted.providerDeletedAt = .now
        let store = MailStore(messages: [first, second, archived, snoozed, deleted, message("remote:other:account")])
        let connected = { Set(RemoteAccountRegistry.accounts.filter { $0.status == "connected" }.map(\.localID)) }
        var badge: Int?
        let counts = MailboxCounts(store: store, defaults: defaults, dockAccounts: connected, writeBadge: { badge = $0 })
        func waitUntil(_ description: String, _ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try check(ready(), description)
        }
        try await waitUntil("Dock badge defaults on and counts visible unread Inbox messages across accounts") {
            counts.showsUnreadInDock && badge == 2
        }
        store.select(first)
        try await waitUntil("reading one message updates the Dock without an open sidebar") { badge == 1 }
        store.moveMessage(second.id, to: .archive)
        try await waitUntil("archiving the last unread message clears the Dock badge") { badge == nil }
        counts.showsUnreadInDock = false
        store.messages.append(message(first.account))
        try await waitUntil("new unread mail leaves a disabled Dock badge hidden") {
            counts.snapshot?.mailboxes[.inbox] == 1 && badge == nil
        }
        let relaunched = MailboxCounts(store: store, defaults: defaults, dockAccounts: connected, writeBadge: { _ in })
        try check(!relaunched.showsUnreadInDock, "Dock badge preference survives relaunch")
        counts.showsUnreadInDock = true
        try check(badge == 1, "re-enabling the Dock badge immediately shows the current count")
        RemoteAccountRegistry.accounts[0].status = "revoked"
        try check(counts.menuBarInbox == nil, "revoking an account hides its menu bar preview before the asynchronous recount")
        try await waitUntil("disconnecting an account removes its unread mail from the Dock and menu bar") {
            badge == nil && counts.menuBarInbox?.count(for: .all) == 0
        }
        RemoteAccountRegistry.accounts = accounts
        try await waitUntil("reconnecting restores its unread count") {
            badge == 1 && counts.menuBarInbox?.count(for: .all) == 1
        }
        counts.showsUnreadInDock = false
        try check(badge == nil, "turning off the preference clears a visible Dock badge immediately")
    }

    @MainActor static func menuBarInboxData() async throws {
        let first = "remote:first"
        let second = "remote:second"
        let hidden = "remote:revoked"
        let accounts: Set<String> = [first, second, hidden]
        let eligible: Set<String> = [first, second]
        func message(_ sequence: Int, account: String = "remote:first") -> MailMessage {
            MailMessage(sender: "Casey", senderEmail: "casey@example.org", initials: "C", subject: "Message " + String(sequence),
                        preview: "", paragraphs: [], timeLabel: "", isUnread: true, account: account,
                        sentAt: Date(timeIntervalSinceReferenceDate: Double(sequence)))
        }
        var people = (0..<8).map { message($0) }
        people[4].workflow.needsReply = true
        people[5].conversationID = people[4].conversationID
        people[5].automaticReplyPending = true
        people[5].isUnread = false
        var separate = message(20, account: second)
        separate.conversationID = people[4].conversationID
        separate.workflow.needsReply = true
        var updates = [message(10), message(11), message(12)]
        updates[0].providerLabelIDs = ["CATEGORY_SOCIAL"]
        updates[1].senderEmail = "no-reply@example.org"
        updates[2].unsubscribeHeaders = MailUnsubscribeHeaders(listUnsubscribe: ["mailto:stop@example.org"],
            listUnsubscribePost: [], authenticationResults: [], dkimSignatures: [], source: "fixture")
        var filtered = (30..<34).map { message($0) }
        filtered[0].workflow.snoozedUntil = .distantFuture
        filtered[1].workflow.screeningState = .pending
        filtered[2].providerDeletedAt = .now
        filtered[3].mailbox = .archive
        filtered[3].workflow.needsReply = true
        let rows = people + updates + filtered + [separate, message(100, account: hidden)]
        let result = try await SidebarCounts.load(rows, accounts: accounts, menuAccounts: eligible).menuBarInbox
        try check(result.count(for: .all) == 11 && result.count(for: .people) == 8 && result.count(for: .updates) == 3,
                  "menu bar filters count eligible unread inbox mail across accounts using the People split")
        try check(result.messages(for: .all).map(\.id) == [separate, updates[2], updates[1], updates[0], people[7], people[6]].map(\.id),
                  "menu bar preview keeps the six latest actual messages in date order")
        try check(result.count(for: .needsReply) == 2 && result.messages(for: .needsReply).map(\.id) == [separate.id, people[5].id],
                  "menu bar reply tasks include read mail, exclude archive and keep accounts' separate conversations")

        let leading = message(100, account: "Work")
        let target = message(70, account: "Personal")
        let store = MailStore(messages: [leading, target])
        store.selectedAccount = "Work"
        store.selectInboxSplit(store.inboxSplits[1].id)
        store.updateSearchText("earlier search")
        try check(!store.revealMessage(UUID()) && store.isSearchActive && store.selectedInboxSplitID != nil
                  && store.selectedAccount == "Work" && store.messages.allSatisfy(\.isUnread),
                  "a stale menu bar target leaves search, mailbox selection and read states untouched")
        try check(store.revealMessage(target.id) && !store.isSearchActive && store.selectedInboxSplitID == nil
                  && store.selectedAccount == nil && store.selectedMailbox == .inbox,
                  "revealing a menu bar message exits search and the previous account's inbox tab")
        await store.loadMailboxView()
        try check(store.selectedMessageID == target.id && store.selectedMessageIDs == [target.id]
                  && store.messages.filter(\.isUnread).map(\.id) == [leading.id],
                  "the reloaded inbox selects and marks only the requested message even when it is not the first row")
    }

    @MainActor static func main() async throws {
        try syncProgress()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PostmereRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try dropOnSidebar()
        try separateBodyStorage(directory: directory)
        try await lazyBodyOpening(directory: directory)
        try await readerPersistence(directory: directory)
        try await dockUnreadCounts()
        try await menuBarInboxData()
        try runSearchSplitRegressions(directory: directory)
        try await runBackgroundSearchRegressions()
        try await runRemoteMailRegressions(directory: directory)
        let workspaceAccount = RemoteAccountIdentity(localID: "remote:fixture:workspace:user:primary", accountID: UUID(),
            scope: "fixture:workspace:user", email: "me@example.com", displayName: "Me", provider: "gmail")
        RemoteAccountRegistry.accounts = [workspaceAccount]
        defer { RemoteAccountRegistry.accounts = [] }
        try mailLinks(directory: directory, account: workspaceAccount)
        try scopedDraftRecovery(directory: directory, account: workspaceAccount)
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
        queuedRestart.onCancelRemoteSend = { id in queuedRestart.restoreQueuedDraft(id) }
        queuedRestart.undoLastSend()
        try check(queuedRestart.outgoingQueue.isEmpty && queuedRestart.isComposing && queuedRestart.draftSubject == "Recover me", "undo send restores editable message")
        queuedRestart.draftSendAt = .now.addingTimeInterval(600)
        queuedRestart.sendDraft()
        let scheduled = queuedRestart.outgoingQueue[0]
        await queuedRestart.processDueWork(now: scheduled.scheduledAt.addingTimeInterval(-1))
        try check(queuedRestart.outgoingQueue.count == 1, "scheduled mail does not deliver early")
        await queuedRestart.processDueWork(now: scheduled.scheduledAt.addingTimeInterval(1))
        try check(queuedRestart.outgoingQueue.count == 1 && queuedRestart.messages.contains { $0.id == scheduled.id && $0.mailbox == .outbox }, "due workspace mail waits for server delivery")
        let deliveredRestart = MailStore(messages: [], persistenceURL: stateURL)
        try check(deliveredRestart.outgoingQueue.count == 1 && deliveredRestart.messages.contains { $0.id == scheduled.id && $0.mailbox == .outbox }, "server-owned send survives restart without local delivery")

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
        try check(abs(savedScheduleRestart.messages[0].workflow.scheduledSendAt!.timeIntervalSince(plannedSend)) < 0.001 && savedScheduleRestart.messages[0].mailbox == .outbox, "unconfirmed workspace send keeps its schedule until the server acknowledges delivery")

        var liveMessage = initial
        liveMessage.account = workspaceAccount.localID
        liveMessage.providerAccountEmail = workspaceAccount.email
        liveMessage.providerMessageID = "live-123"
        liveMessage.mailbox = .sent
        let live = MailStore(messages: [liveMessage])
        let liveID = liveMessage.id
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
        let beforeArchive = batch.mailboxDataRevision
        batch.moveMessages(batch.selectedMessageIDs, to: .archive)
        try check(batch.mailboxDataRevision == beforeArchive + 1, "bulk archive publishes one mailbox mutation")
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
        let beforeRestore = mixedRestore.mailboxDataRevision
        mixedRestore.restoreSelected()
        try check(mixedRestore.mailboxDataRevision == beforeRestore + 1, "bulk restore publishes one mailbox mutation")
        try check(mixedRestore.messages.contains { $0.id == trashedDraft.id && $0.mailbox == .drafts }
                  && mixedRestore.messages.contains { $0.id == trashedArchive.id && $0.mailbox == .archive },
                  "batch restore respects each message’s original destination")

        let rowOrder = (0..<160).map { _ in
            var row = other
            row.id = UUID()
            return row
        }
        let progressiveBatch = MailStore(messages: rowOrder)
        await progressiveBatch.loadMailboxView()
        let middle = Set(rowOrder[40..<120].map(\.id))
        progressiveBatch.setSelection(middle)
        let oldLead = progressiveBatch.selectedMessageID
        progressiveBatch.moveSelected(to: .archive)
        await progressiveBatch.loadMailboxView()
        try check(progressiveBatch.selectedMessageID == rowOrder[120].id && progressiveBatch.messages.map(\.id) == rowOrder.map(\.id),
                  "a bulk move advances to the next surviving row without reordering mail")
        progressiveBatch.undoLastMove()
        await progressiveBatch.loadMailboxView()
        try check(progressiveBatch.selectedMessageIDs == middle && progressiveBatch.selectedMessageID == oldLead,
                  "undo restores the whole selection and its lead after the mailbox has refreshed")

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

        let legacyURL = directory.appendingPathComponent("legacy.json")
        var oldAccount = initial
        oldAccount.account = MailAccount.gmail.rawValue
        oldAccount.providerAccountEmail = "old@example.com"
        oldAccount.providerMessageID = "same-provider-id"
        oldAccount.rfcMessageID = "same-message-id"
        oldAccount.mailbox = .outbox
        oldAccount.workflow.privateNote = "Keep legacy notes"
        let legacy = MailStore(messages: [oldAccount], persistenceURL: legacyURL)
        legacy.outgoingQueue = [OutgoingMailItem(messageID: oldAccount.id, queuedAt: .now, undoUntil: .now, scheduledAt: .now)]
        let legacyRestart = MailStore(persistenceURL: legacyURL)
        try check(legacyRestart.outgoingQueue.first?.status == .failed && legacyRestart.outgoingQueue.first?.lastError?.contains("workspace") == true,
                  "legacy direct sends are stopped after relaunch without being transferred")
        await legacyRestart.processDueWork(now: .now.addingTimeInterval(600))
        try check(legacyRestart.messages.first?.mailbox == .outbox && legacyRestart.messages.first?.workflow.privateNote == "Keep legacy notes",
                  "stopping legacy sends preserves content and private notes")
        legacyRestart.retrySend(oldAccount.id)
        try check(legacyRestart.outgoingQueue.first?.status == .failed, "legacy retries cannot re-enable direct delivery")
        try check(legacyRestart.previousAccountDrafts.map(\.id) == [oldAccount.id], "stopped legacy sends remain explicitly recoverable")
        legacyRestart.reviewPreviousAccountDraft(id: oldAccount.id)
        try check(legacyRestart.isComposing && !legacyRestart.canSendDraft, "legacy draft recovery requires choosing a workspace account")
        legacyRestart.draftAccount = MailAccount(rawValue: workspaceAccount.localID)!
        legacyRestart.draftTo = "recipient@example.com"
        try check(legacyRestart.canSendDraft, "explicitly selecting a connected workspace account enables a recovered draft")
        let ambiguousURL = directory.appendingPathComponent("legacy-ambiguous.json")
        let ambiguous = MailStore(messages: [oldAccount], persistenceURL: ambiguousURL)
        var interruptedLegacy = OutgoingMailItem(messageID: oldAccount.id, queuedAt: .now, undoUntil: .now, scheduledAt: .now)
        interruptedLegacy.status = .delivering
        interruptedLegacy.lastError = "Original provider warning."
        ambiguous.outgoingQueue = [interruptedLegacy]
        let ambiguousRestart = MailStore(persistenceURL: ambiguousURL)
        try check(ambiguousRestart.outgoingQueue[0].lastError?.contains("Original provider warning") == true
                  && ambiguousRestart.outgoingQueue[0].lastError?.contains("Check Sent") == true,
                  "legacy interrupted sends retain provider details and duplicate-delivery warning")
        let ambiguousAgain = MailStore(persistenceURL: ambiguousURL)
        try check(ambiguousAgain.outgoingQueue[0].lastError == ambiguousRestart.outgoingQueue[0].lastError,
                  "legacy delivery warnings remain stable across repeated relaunches")
        let formerIdentity = legacyRestart.draftAccount
        RemoteAccountRegistry.accounts = []
        try check(!legacyRestart.canSendDraft && MailAccount.allCases.isEmpty, "sign-out removes sender choices and blocks existing drafts")
        RemoteAccountRegistry.accounts = [workspaceAccount]
        try check(legacyRestart.draftAccount == formerIdentity && legacyRestart.canSendDraft, "reconnecting the same scoped account restores draft availability")
        var reconnectRequired = workspaceAccount
        reconnectRequired.status = "reconnect_required"
        RemoteAccountRegistry.accounts = [reconnectRequired]
        try check(!legacyRestart.canSendDraft && MailAccount.sendingAccounts.isEmpty, "revoked provider access blocks sending while preserving the account")
        RemoteAccountRegistry.accounts = [workspaceAccount]
        let fresh = MailStore(persistenceURL: directory.appendingPathComponent("empty.json"))
        try check(fresh.messages.isEmpty && !MailAccount.allCases.contains(.work) && !MailAccount.allCases.contains(.gmail),
                  "fresh workspace-only mailboxes never seed sample or direct accounts")
        var newAccount = oldAccount
        newAccount.id = UUID()
        newAccount.account = workspaceAccount.localID
        newAccount.providerAccountEmail = workspaceAccount.email
        newAccount.backendMessageID = UUID()
        newAccount.mailbox = .inbox
        newAccount.workflow = MailWorkflowState()
        let identities = MailStore(messages: [oldAccount])
        identities.mergeIncoming([newAccount])
        try check(identities.messages.count == 2 && identities.filteredMessages.map(\.id) == [newAccount.id],
                  "workspace mail does not merge into or expose legacy direct mail")
        try check(identities.filteredMessages[0].workflow.privateNote.isEmpty, "private notes do not leak into newly connected accounts")
        identities.setPrivateNote("Keep this deleted email’s context", for: newAccount.id)
        identities.setFollowUp(newAccount.id, at: .now.addingTimeInterval(60))
        let deletion = BackendMailPage(messages: [], nextCursor: "deleted", hasMore: false, deletedMessageIds: [newAccount.backendMessageID!])
        _ = await identities.applyBackendPage(deletion, identity: workspaceAccount)
        try check(identities.messages.count == 2 && identities.filteredMessages.isEmpty && identities.notificationSchedules.isEmpty,
                  "workspace deletion hides original mail while retaining local notes")
        try check(identities.messages.first(where: { $0.id == newAccount.id })?.workflow.privateNote == "Keep this deleted email’s context",
                  "workspace deletion preserves private notes")
        identities.mergeIncoming([newAccount])
        try check(identities.filteredMessages.count == 1 && !identities.filteredMessages[0].isDeletedOnProvider,
                  "a later successful workspace read restores hidden mail")
        var retainedDraft = newAccount
        retainedDraft.id = UUID()
        retainedDraft.mailbox = .drafts
        let draftDeletion = MailStore(messages: [retainedDraft])
        _ = await draftDeletion.applyBackendPage(deletion, identity: workspaceAccount)
        draftDeletion.selectMailbox(.drafts)
        try check(draftDeletion.filteredMessages.count == 1 && draftDeletion.messages[0].isDeletedOnProvider,
                  "provider deletion never hides or removes local saved drafts")
        print("All backend regressions passed")
    }

    static func syncProgress() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let idle = try decoder.decode(BackendMailPage.self, from: Data(#"{"messages":[],"has_more":false}"#.utf8))
        try check(idle.syncStatus == nil, "older servers omit sync status")
        let waiting = try decoder.decode(BackendMailPage.self, from: Data(#"{"messages":[],"has_more":false,"sync_status":{"phase":"retrying","retry_at":"2026-11-20T12:08:00Z"}}"#.utf8))
        try check(waiting.syncStatus?.phase == "retrying" && waiting.syncStatus?.retryAt != nil, "a cooldown retains its server retry time")
        try check(!MailSyncActivity.idle.isActive && MailSyncActivity.idle.detail == nil, "idle sync has no sidebar indicator")
        try check(MailSyncActivity.loadingCache(loaded: 1).explanation.contains("1 message loaded"), "loading announces the confirmed local count")
        try check(MailSyncActivity.importing(cached: nil).detail == nil, "an import with no count shows indeterminate progress")
    }

    @MainActor static func mailLinks(directory: URL, account: RemoteAccountIdentity) throws {
        let links = MailLinkDrafts()
        let path = directory.appendingPathComponent("email-link.json")
        let store = MailStore(messages: [], persistenceURL: path)
        let url = URL(string: "mailto:a+tag@example.com,b@example.com?to=c@example.com&cc=d@example.com&bcc=e@example.com&subject=Caf%C3%A9%20%26%20tea&body=A%2BB%0D%0AC&from=ignored@example.com&attach=/tmp/ignored")!
        try check(links.receive(url, verifiedScope: nil) && !links.openNext(in: store, verifiedScope: nil),
                  "a cold mail link waits for verified access")
        links.useWorkspace(account.scope)
        try check(links.openNext(in: store, verifiedScope: account.scope) && store.isComposing
                  && store.draftAccount.rawValue == account.localID && store.draftAttachments.isEmpty && store.outgoingQueue.isEmpty
                  && store.draftTo == "a+tag@example.com, b@example.com, c@example.com" && store.draftCc == "d@example.com"
                  && store.draftBcc == "e@example.com" && store.draftSubject == "Café & tea" && store.draftBody == "A+B\nC",
                  "mailto opens a scoped editable draft and decodes all supported fields")
        let second = URL(string: "mailto:second@example.com")!
        links.receive(second, verifiedScope: account.scope)
        try check(!links.openNext(in: store, verifiedScope: account.scope) && store.draftSubject == "Café & tea",
                  "a second mail link preserves the current draft")
        try check(store.flushPersistence(), "the first link draft is recoverable")
        let reopened = MailStore(messages: [], persistenceURL: path)
        try check(!links.openNext(in: reopened, verifiedScope: account.scope) && reopened.draftRecoveryAvailable,
                  "a link waits while an unfinished draft can be recovered")
        reopened.recoverDraft()
        reopened.saveDraft()
        try check(links.openNext(in: reopened, verifiedScope: account.scope) && reopened.draftTo == "second@example.com",
                  "the next link opens after the previous draft is saved")
        links.receive(second, verifiedScope: account.scope)
        links.useWorkspace(nil)
        try check(!links.hasPending, "signing out clears links associated with that workspace")
        for bad in ["https://example.com", "mailto://site/example.com", "mailto:a@example.com?subject=Hi%0ABcc%3A",
                    "mailto:?to=a@example.com%0D%0Ab@example.com", "mailto:?subject=a&subject=b"] {
            try check(MailLinkDraft(url: URL(string: bad)!) == nil, "unsupported URL or invalid headers are rejected")
        }
    }

    @MainActor static func scopedDraftRecovery(directory: URL, account: RemoteAccountIdentity) throws {
        let stateURL = directory.appendingPathComponent("scoped-draft-recovery.json")
        let original = MailStore(messages: [], persistenceURL: stateURL)
        original.beginCompose()
        original.draftTo = "unfinished address"
        original.draftSubject = "Workspace A draft"
        original.draftBody = "Saved body"
        original.saveDraft()
        let originalID = original.messages[0].id
        original.setPrivateNote("A private draft note", for: originalID)
        original.beginEditingDraft(original.messages[0])
        original.draftBody = "Latest workspace A body"
        original.draftBodyRTF = Data("A rich body".utf8)
        original.draftAttachments = [MailAttachment(name: "A.txt", detail: "A attachment")]
        let plannedSend = Date.now.addingTimeInterval(3_600)
        original.draftSendAt = plannedSend

        // Match provider/email/account UUID to ensure that only the complete
        // current workspace/user identity can make a recovery visible.
        let other = RemoteAccountIdentity(localID: "remote:fixture:other:user:primary", accountID: account.accountID,
            scope: "fixture:other:user", email: account.email, displayName: "Other", provider: account.provider)
        RemoteAccountRegistry.accounts = [other]
        defer { RemoteAccountRegistry.accounts = [account] }
        let switched = MailStore(messages: [], persistenceURL: stateURL)
        try check(!switched.draftRecoveryAvailable, "another workspace cannot offer the previous workspace's active draft")
        switched.recoverDraft()
        switched.discardRecoveredDraft()
        try check(!switched.isComposing && switched.recoveredDraft?.body == "Latest workspace A body",
                  "direct recovery and discard cannot expose or delete an unavailable workspace draft")
        let links = MailLinkDrafts()
        links.receive(URL(string: "mailto:new@example.com")!, verifiedScope: other.scope)
        try check(links.openNext(in: switched, verifiedScope: other.scope),
                  "an email link can open when the recovery belongs to another workspace")
        try check(switched.isComposing && switched.draftAccount.rawValue == other.localID && switched.draftBody != "Latest workspace A body",
                  "new composition cannot automatically reopen another workspace's recovery")
        let preserved = switched.messages.first { $0.id == originalID }!
        try check(preserved.account == account.localID && preserved.paragraphs == ["Latest workspace A body"]
                  && preserved.bodyRTF == Data("A rich body".utf8) && preserved.attachments.first?.name == "A.txt"
                  && preserved.toRecipients == ["unfinished address"] && preserved.workflow.privateNote == "A private draft note"
                  && abs(preserved.workflow.scheduledSendAt!.timeIntervalSince(plannedSend)) < 0.001,
                  "starting another workspace's draft preserves hidden recovery content, files, timing, note, and original ID")
        try check(!switched.isAccountVisible(preserved), "preserved workspace A recovery stays hidden under workspace B")
        switched.draftSubject = "Workspace B draft"
        switched.draftBody = "Latest workspace B body"

        let restarted = MailStore(messages: [], persistenceURL: stateURL)
        try check(restarted.draftRecoveryAvailable && restarted.recoveredDraft?.account.rawValue == other.localID
                  && restarted.messages.first(where: { $0.id == originalID })?.paragraphs == ["Latest workspace A body"],
                  "both workspace drafts survive restart despite the singleton active-draft slot")
        RemoteAccountRegistry.accounts = [account]
        try check(!restarted.draftRecoveryAvailable, "switching back does not expose workspace B's active recovery")
        restarted.beginEditingDraft(restarted.messages.first { $0.id == originalID }!)
        try check(restarted.isComposing && restarted.editingDraftID == originalID && restarted.draftBody == "Latest workspace A body"
                  && restarted.messages.contains { $0.account == other.localID && $0.mailbox == .drafts && $0.paragraphs == ["Latest workspace B body"] },
                  "returning to workspace A restores its draft and preserves workspace B's unsaved draft")

        let legacyURL = directory.appendingPathComponent("legacy-active-recovery.json")
        let legacy = MailStore(messages: [], persistenceURL: legacyURL)
        legacy.beginCompose(); legacy.draftAccount = .gmail; legacy.draftBody = "Previous local account draft"
        let legacyRestart = MailStore(messages: [], persistenceURL: legacyURL)
        try check(legacyRestart.draftRecoveryAvailable, "previous local-account recovery remains available after workspace sign-in")
        legacyRestart.recoverDraft()
        try check(legacyRestart.isComposing && legacyRestart.draftBody == "Previous local account draft" && !legacyRestart.canSendDraft,
                  "legacy recovery preserves content and still requires choosing a connected workspace sender")
    }
}
