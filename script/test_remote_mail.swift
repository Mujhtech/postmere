import Foundation

@MainActor func runRemoteMailRegressions(directory: URL) async throws {
    func check(_ condition: Bool, _ description: String) throws { try PostmereBackendRegression.check(condition, description) }
    let accountID = UUID(), messageID = UUID()
    let first = RemoteAccountIdentity(localID: "remote:server-a:workspace:user:\(accountID)", accountID: accountID, scope: "server-a:workspace:user", email: "me@example.com", displayName: "Me", provider: "gmail")
    let second = RemoteAccountIdentity(localID: "remote:server-b:workspace:user:\(accountID)", accountID: accountID, scope: "server-b:workspace:user", email: "me@example.com", displayName: "Me", provider: "gmail")
    RemoteAccountRegistry.accounts = [first, second]
    defer { RemoteAccountRegistry.accounts = [] }
    var payload = BackendMailMessage(id: messageID, accountId: accountID, providerMessageId: "provider-1", providerThreadId: "thread-1",
        subject: "A remote message", from: BackendAddress(name: "Sender", email: "sender@example.com"), to: [BackendAddress(name: "Alex", email: "me@example.com")], cc: [], bcc: [],
        textBody: "Message body", htmlBody: nil, preview: "Message body", sentAt: .now, isRead: false, isStarred: false, mailbox: "inbox", providerLabels: [], attachments: [], listUnsubscribe: [], listUnsubscribePost: [])
    payload.deliveryHeaders = MailDeliveryHeaders(returnPath: "<bounce@mailer.example.com>", receivedWith: "ESMTPS")
    payload.dkimSignatures = ["v=1; a=rsa-sha256;\r\n d=EXAMPLE.com; s=primary; b=abc",
                              "d=example.com; b=second", "d=ambiguous.example; d=other.example", "d=<invalid>"]
    let one = payload.localMessage(identity: first), two = payload.localMessage(identity: second)
    try check(one.envelopeDetails?.signingDomains == ["example.com"] && one.envelopeDetails?.deliveryHeaders?.receivedWith == "ESMTPS"
              && one.envelopeDetails?.recipientNames["me@example.com"] == "Alex", "reader preserves delivery headers and display names, and rejects ambiguous signer domains")
    var needsReply = one
    needsReply.workflow.needsReply = true
    var earlier = needsReply
    earlier.id = UUID()
    earlier.sentAt = needsReply.sentAt.addingTimeInterval(-60)
    var reminder = one
    reminder.id = UUID()
    reminder.conversationID = UUID()
    reminder.mailbox = .sent
    reminder.workflow.followUpAt = .now
    let overviewStore = MailStore(messages: [needsReply, earlier, reminder, two], persistenceURL: directory.appendingPathComponent("overview.json"))
    overviewStore.selectedAccount = first.localID
    overviewStore.selectedMessageID = nil
    let overview = InboxOverview(store: overviewStore)
    try check(overview.isInbox && overview.sections.map(\.mailbox) == [.needsReply, .followUps]
              && overview.sections.flatMap(\.messages).map(\.id) == [needsReply.id, reminder.id],
              "inbox overview keeps account boundaries, deduplicates thread entries and includes sent follow-ups")
    overviewStore.searchText = "no-such-subject"
    let search = InboxOverview(store: overviewStore)
    try check(!search.isInbox && search.sections.isEmpty, "an empty search never shows unrelated mail in the reader")
    try checkReceivedBodyRecovery(one, directory: directory)
    try checkTrackingPixelRules()
    try check(one.id != two.id && one.conversationID != two.conversationID, "identical server IDs remain isolated across server identities")
    let stateURL = directory.appendingPathComponent("remote-state.json")
    let store = MailStore(messages: [two], persistenceURL: stateURL)
    let page = BackendMailPage(messages: [payload], nextCursor: "cursor-one", hasMore: false)
    try check(await store.applyBackendPage(page, identity: first), "remote page and cursor persist successfully")
    let reopened = MailStore(messages: [], persistenceURL: stateURL)
    try check(reopened.backendSyncCursors[first.localID] == "cursor-one" && reopened.messages.contains { $0.id == one.id }, "remote cursor never outruns its durable messages")
    let deleted = BackendMailPage(messages: [], nextCursor: "cursor-two", hasMore: false, deletedMessageIds: [messageID])
    try check(await store.applyBackendPage(deleted, identity: first), "explicit provider deletion page persists")
    try check(store.messages.first { $0.id == one.id }?.isDeletedOnProvider == true && store.messages.first { $0.id == two.id }?.isDeletedOnProvider == false, "deletion affects only its server-account namespace")

    let backgroundURL = directory.appendingPathComponent("sync-during-input.json")
    let backgroundStore = MailStore(messages: [], persistenceURL: backgroundURL)
    let releaseWriter = DispatchSemaphore(value: 0)
    backgroundStore.saveQueue.async { _ = releaseWriter.wait(timeout: .now() + 5) }
    let sync = Task { await backgroundStore.applyBackendPage(page, identity: first) }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while backgroundStore.backendSyncCursors[first.localID] == nil && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    let receivedWhileBlocked = backgroundStore.messages.contains { $0.id == one.id } && clock.now < deadline
    let snapshotBeforeWrite = try? MailPersistence(fileURL: backgroundURL).load()
    releaseWriter.signal()
    let wrotePage = await sync.value
    try check(receivedWhileBlocked && wrotePage && snapshotBeforeWrite != nil
              && snapshotBeforeWrite?.backendSyncCursors[first.localID] == nil,
              "provider pages publish to the interactive mailbox while the durable writer is busy")
    let stalePage = await backgroundStore.applyBackendPage(deleted, identity: first, isCurrent: { false })
    try check(!stalePage && backgroundStore.backendSyncCursors[first.localID] == "cursor-one"
              && backgroundStore.messages.first?.isDeletedOnProvider == false,
              "a provider page from an abandoned account cannot install rows or advance its cursor")

    let brokenURL = directory.appendingPathComponent("blocked-remote-state.json")
    try Data("invalid JSON".utf8).write(to: brokenURL)
    let blocked = MailStore(messages: [], persistenceURL: brokenURL)
    blocked.backendSyncCursors[first.localID] = "old-cursor"
    try check(await !blocked.applyBackendPage(page, identity: first) && blocked.backendSyncCursors[first.localID] == "old-cursor", "failed mailbox persistence keeps the previous remote cursor")
    try check(await !blocked.prepareBackendNotifications(for: first) && blocked.backendNotificationCutoffs[first.localID] == nil,
              "failed storage cannot establish an undurable notification baseline")

    let notificationURL = directory.appendingPathComponent("remote-notifications.json")
    let notificationStore = MailStore(messages: [], persistenceURL: notificationURL)
    let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
    try check(await notificationStore.prepareBackendNotifications(for: first, now: cutoff), "remote notification baseline persists before any page is fetched")
    let beforeFetch = MailStore(messages: [], persistenceURL: notificationURL)
    try check(beforeFetch.backendNotificationCutoffs[first.localID] == cutoff && beforeFetch.messages.isEmpty,
              "notification baseline survives an interruption before the first sync response")
    func notificationPayload(offset: TimeInterval) -> BackendMailMessage {
        let id = UUID()
        return BackendMailMessage(id: id, accountId: accountID, providerMessageId: id.uuidString, providerThreadId: id.uuidString,
            subject: "Notification fixture", from: BackendAddress(email: "sender@example.com"), to: [BackendAddress(email: first.email)], cc: [], bcc: [],
            textBody: "Notification fixture", htmlBody: nil, preview: "Notification fixture", sentAt: cutoff.addingTimeInterval(offset),
            isRead: false, isStarred: false, mailbox: "inbox", providerLabels: [], attachments: [], listUnsubscribe: [], listUnsubscribePost: [])
    }
    let historical = notificationPayload(offset: -86_400)
    let arrivedDuringSetup = notificationPayload(offset: 1)
    try check(await notificationStore.applyBackendPage(BackendMailPage(messages: [historical, arrivedDuringSetup], nextCursor: "bootstrap-one", hasMore: true), identity: first),
              "first sync may contain both older mail and a new arrival")
    try check(notificationStore.backendNotificationCandidates(for: first, excluding: []).map(\.backendMessageID) == [arrivedDuringSetup.id],
              "initial sync notifies only mail arriving after setup began")
    let firstPageIDs = Set(notificationStore.messages.map(\.id))
    let older = notificationPayload(offset: -864_000)
    try check(await notificationStore.applyBackendPage(BackendMailPage(messages: [older], nextCursor: "bootstrap-two", hasMore: false), identity: first),
              "later bootstrap history advances the cursor")
    try check(notificationStore.backendNotificationCandidates(for: first, excluding: firstPageIDs).isEmpty,
              "a nonempty cursor does not turn paginated historical imports into new mail notifications")

    let afterReopen = MailStore(messages: [], persistenceURL: notificationURL)
    afterReopen.backendSyncCursors[first.localID] = nil
    try check(await afterReopen.prepareBackendNotifications(for: first, now: cutoff.addingTimeInterval(172_800))
              && afterReopen.backendNotificationCutoffs[first.localID] == cutoff,
              "relaunch and cursor replay preserve the original notification date")
    let knownAfterReopen = Set(afterReopen.messages.map(\.id))
    let arrivedWhileClosed = notificationPayload(offset: 86_400)
    let laterHistoricalImport = notificationPayload(offset: -1_728_000)
    try check(await afterReopen.applyBackendPage(BackendMailPage(messages: [historical, arrivedWhileClosed, laterHistoricalImport], nextCursor: "replayed", hasMore: false), identity: first),
              "cursor replay can contain offline arrivals alongside older history")
    try check(afterReopen.backendNotificationCandidates(for: first, excluding: knownAfterReopen).map(\.backendMessageID) == [arrivedWhileClosed.id],
              "offline arrivals still notify while replayed messages and older backfills remain quiet")
    try check(afterReopen.backendNotificationCandidates(for: second, excluding: []).isEmpty,
              "notification eligibility never crosses server-account identities")

    let policyStore = MailStore(messages: [], persistenceURL: directory.appendingPathComponent("notification-policy.json"))
    var policyEdits = 0
    policyStore.onNotificationPolicyChanged = { policyEdits += 1 }
    policyStore.senderScreeningEnabled = true
    try check(!policyStore.permitsIncomingNotification(one), "current sender screening silences unknown incoming notifications")
    let accepted = SenderRule(email: one.senderEmail, account: first.localID, route: .inbox)
    let blockedRule = SenderRule(email: one.senderEmail, route: .blocked)
    policyStore.saveSenderRule(accepted, applyToExisting: false)
    policyStore.saveSenderRule(blockedRule, applyToExisting: false)
    try check(policyStore.permitsIncomingNotification(one) && !policyStore.permitsIncomingNotification(two),
              "notification routing preserves ordered first-match rules and account boundaries")
    policyStore.deleteSenderRule(accepted.id)
    try check(!policyStore.permitsIncomingNotification(one), "removing a sender approval exposes the following blocking rule immediately")
    policyStore.deleteSenderRule(blockedRule.id)
    policyStore.saveSenderRule(SenderRule(email: one.senderEmail, account: first.localID, route: .needsReply,
                                         providerAccountEmail: "another@example.com"), applyToExisting: false)
    try check(!policyStore.permitsIncomingNotification(one), "a rule for another provider identity cannot approve incoming notifications")
    policyStore.saveSenderRule(SenderRule(email: one.senderEmail, account: first.localID, route: .needsReply,
                                         providerAccountEmail: first.email.uppercased()), applyToExisting: false)
    try check(policyStore.permitsIncomingNotification(one), "needs-reply approvals allow incoming alerts for their scoped provider identity")
    var archived = one; archived.mailbox = .archive
    var read = one; read.isUnread = false
    try check(!policyStore.permitsIncomingNotification(archived) && !policyStore.permitsIncomingNotification(read),
              "sender approval never revives archived or read incoming alerts")
    policyStore.senderScreeningEnabled = false
    try check(policyEdits == 8, "screening/rule additions, edits and removals do not immediately request remote-policy synchronization")

    let queueStore = MailStore(messages: [], persistenceURL: directory.appendingPathComponent("remote-queue.json"))
    queueStore.beginCompose(account: MailAccount(rawValue: first.localID)!)
    queueStore.draftTo = "recipient@example.com"
    queueStore.draftSubject = "Remote delivery"
    queueStore.draftBody = "Delivery belongs to the workspace server"
    queueStore.sendDraft()
    try check(queueStore.outgoingQueue.count == 1, "remote send enters the durable queue")
    let queuedID = queueStore.outgoingQueue[0].id
    try check(queueStore.messages[0].rfcMessageID == "<\(queuedID.uuidString.lowercased())@postmere.local>", "remote MIME Message-ID matches the stable server send identifier")
    var earlySent = BackendMailMessage(id: messageID, accountId: accountID, providerMessageId: "provider-1", providerThreadId: "thread-1",
        subject: "Remote delivery", from: BackendAddress(email: first.email), to: [BackendAddress(email: "recipient@example.com")], cc: [], bcc: [],
        textBody: "Provider copy", htmlBody: nil, preview: "Provider copy", sentAt: .now, isRead: true, isStarred: false, mailbox: "sent", providerLabels: [], attachments: [], listUnsubscribe: [], listUnsubscribePost: [])
    earlySent.rfcMessageId = queueStore.messages[0].rfcMessageID
    let earlyPage = BackendMailPage(messages: [earlySent], nextCursor: "early-sent", hasMore: false)
    try check(await queueStore.applyBackendPage(earlyPage, identity: first), "early server Sent metadata and cursor persist together")
    try check(queueStore.messages.count == 1 && queueStore.messages[0].id == queuedID
              && queueStore.messages[0].mailbox == .outbox && queueStore.messages[0].backendMessageID == messageID
              && queueStore.messages[0].providerMessageID == "provider-1"
              && queueStore.messages[0].providerThreadID == "thread-1"
              && queueStore.messages[0].paragraphs == ["Delivery belongs to the workspace server"], "sync before an outbox poll preserves pending state and remote identifiers without duplicating the message")
    await queueStore.processDueWork(now: .now.addingTimeInterval(600))
    try check(queueStore.outgoingQueue.first?.status == .pending && queueStore.messages.first?.mailbox == .outbox, "local delivery worker never sends a server-owned queue item")
    let resumedQueue = MailStore(messages: [], persistenceURL: directory.appendingPathComponent("remote-queue.json"))
    try check(resumedQueue.outgoingQueue.first?.id == queueStore.outgoingQueue.first?.id, "remote delivery idempotency ID survives restart")
    try check(resumedQueue.messages.count == 1 && resumedQueue.messages[0].backendMessageID == messageID
              && resumedQueue.messages[0].rfcMessageID == earlySent.rfcMessageId
              && resumedQueue.backendSyncCursors[first.localID] == "early-sent", "early provider identifiers survive restart together with the advanced cursor")
}

@MainActor private func checkTrackingPixelRules() throws {
    let pixel = "https://mail.sendgrid.net/wf/open?upn=A+B.c"
    let encoded = try MailTrackingPixelRules.encoded(for: [pixel, pixel])
    let rules = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: [String: Any]]]
    let trigger = rules?.first?["trigger"]
    let pattern = trigger?["url-filter"] as? String
    try PostmereBackendRegression.check(rules?.count == 1 && rules?.first?["action"]?["type"] as? String == "block"
        && trigger?["url-filter-is-case-sensitive"] as? Bool == true
        && pattern.map { pixel.range(of: $0, options: .regularExpression) != nil } == true,
        "duplicate tracking URLs yield one exact, case-sensitive WebKit blocker")
    let allowed = ["https://mail.sendgrid.net/logo.png", pixel + "2", pixel.replacingOccurrences(of: "+", with: "")]
    try PostmereBackendRegression.check(pattern.map { regex in
        allowed.allSatisfy { $0.range(of: regex, options: .regularExpression) == nil }
    } == true, "the blocker leaves ordinary assets and distinct recipient URLs alone")
}

@MainActor private func checkReceivedBodyRecovery(_ source: MailMessage, directory: URL) throws {
    let check = PostmereBackendRegression.check
    let html = "<html><head><style>p {color:navy}</style></head><body><p>Alex&#39;s tea &amp; coffee</p><p>Closing invitation</p></body></html>"
    func cached(_ paragraphs: [String], preview: String, html: String?) -> MailMessage {
        var message = source
        message.id = UUID()
        message.paragraphs = paragraphs
        message.preview = preview
        message.bodyHTML = html
        return message
    }
    let gmail = cached([""], preview: "Alex&#39;s tea &amp; coffee", html: html)
    let graph = cached(["Alex's tea"], preview: "Alex's tea", html: html)
    let multipart = cached(["Independent plain alternative"], preview: "Independent plain alternative", html: html)
    let code = "Use <p>text &amp; code</p>."
    let plain = cached([code], preview: code, html: nil)
    var draft = cached(["Edited locally"], preview: "Edited locally", html: html)
    draft.mailbox = .drafts
    let url = directory.appendingPathComponent("historical-mail-body.json")
    let legacy = MailStore(messages: [gmail, graph, multipart, plain, draft], persistenceURL: url)
    try check(legacy.persistState(), "historical mail fixtures persist")
    let reopened = MailStore(messages: [], persistenceURL: url)
    guard let gmail = reopened.messages.first(where: { $0.id == gmail.id }),
          let graph = reopened.messages.first(where: { $0.id == graph.id }) else {
        throw RegressionFailure.failed("historical messages missing after restart")
    }
    try check(gmail.receivedHTML == html && graph.receivedHTML == html, "cached HTML survives offline restore")
    try check(gmail.preview == "Alex's tea & coffee" &&
              MailSearchQuery(source: "invitation").matches(gmail) && MailSearchQuery(source: "invitation").matches(graph),
              "HTML-only and preview-only caches restore full searchable text and decoded list snippets")
    try check(!MailSearchQuery(source: "navy").matches(gmail), "email stylesheet rules stay out of local search")
    try check(reopened.messages.first { $0.id == multipart.id }?.paragraphs == multipart.paragraphs,
              "multipart cache preserves the sender's independent text alternative")
    try check(reopened.messages.first { $0.id == plain.id }?.receivedHTML == nil &&
              reopened.messages.first { $0.id == plain.id }?.preview == code, "plain-text markup examples remain literal")
    try check(reopened.messages.first { $0.id == draft.id }?.receivedHTML == nil &&
              reopened.messages.first { $0.id == draft.id }?.paragraphs == draft.paragraphs,
              "drafts use their current editable text")
}
