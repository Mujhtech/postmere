import Foundation

@MainActor func runRemoteMailRegressions(directory: URL) async throws {
    let check = PostmereBackendRegression.check
    let accountID = UUID(), messageID = UUID()
    let first = RemoteAccountIdentity(localID: "remote:server-a:workspace:user:\(accountID)", accountID: accountID, scope: "server-a:workspace:user", email: "me@example.com", displayName: "Me", provider: "gmail")
    let second = RemoteAccountIdentity(localID: "remote:server-b:workspace:user:\(accountID)", accountID: accountID, scope: "server-b:workspace:user", email: "me@example.com", displayName: "Me", provider: "gmail")
    RemoteAccountRegistry.accounts = [first, second]
    defer { RemoteAccountRegistry.accounts = [] }
    let payload = BackendMailMessage(id: messageID, accountId: accountID, providerMessageId: "provider-1", providerThreadId: "thread-1",
        subject: "A remote message", from: BackendAddress(email: "sender@example.com"), to: [BackendAddress(email: "me@example.com")], cc: [], bcc: [],
        textBody: "Message body", htmlBody: nil, preview: "Message body", sentAt: .now, isRead: false, isStarred: false, mailbox: "inbox", providerLabels: [], attachments: [], listUnsubscribe: [], listUnsubscribePost: [])
    let one = payload.localMessage(identity: first), two = payload.localMessage(identity: second)
    try check(one.id != two.id && one.conversationID != two.conversationID, "identical server IDs remain isolated across server identities")
    let stateURL = directory.appendingPathComponent("remote-state.json")
    let store = MailStore(messages: [two], persistenceURL: stateURL)
    let page = BackendMailPage(messages: [payload], nextCursor: "cursor-one", hasMore: false)
    try check(store.applyBackendPage(page, identity: first), "remote page and cursor persist successfully")
    let reopened = MailStore(messages: [], persistenceURL: stateURL)
    try check(reopened.backendSyncCursors[first.localID] == "cursor-one" && reopened.messages.contains { $0.id == one.id }, "remote cursor never outruns its durable messages")
    let deleted = BackendMailPage(messages: [], nextCursor: "cursor-two", hasMore: false, deletedMessageIds: [messageID])
    try check(store.applyBackendPage(deleted, identity: first), "explicit provider deletion page persists")
    try check(store.messages.first { $0.id == one.id }?.isDeletedOnProvider == true && store.messages.first { $0.id == two.id }?.isDeletedOnProvider == false, "deletion affects only its server-account namespace")
    let brokenURL = directory.appendingPathComponent("blocked-remote-state.json")
    try Data("invalid JSON".utf8).write(to: brokenURL)
    let blocked = MailStore(messages: [], persistenceURL: brokenURL)
    blocked.backendSyncCursors[first.localID] = "old-cursor"
    try check(!blocked.applyBackendPage(page, identity: first) && blocked.backendSyncCursors[first.localID] == "old-cursor", "failed mailbox persistence keeps the previous remote cursor")
    try check(!blocked.prepareBackendNotifications(for: first) && blocked.backendNotificationCutoffs[first.localID] == nil,
              "failed storage cannot establish an undurable notification baseline")

    let notificationURL = directory.appendingPathComponent("remote-notifications.json")
    let notificationStore = MailStore(messages: [], persistenceURL: notificationURL)
    let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
    try check(notificationStore.prepareBackendNotifications(for: first, now: cutoff), "remote notification baseline persists before any page is fetched")
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
    try check(notificationStore.applyBackendPage(BackendMailPage(messages: [historical, arrivedDuringSetup], nextCursor: "bootstrap-one", hasMore: true), identity: first),
              "first sync may contain both older mail and a new arrival")
    try check(notificationStore.backendNotificationCandidates(for: first, excluding: []).map(\.backendMessageID) == [arrivedDuringSetup.id],
              "initial sync notifies only mail arriving after setup began")
    let firstPageIDs = Set(notificationStore.messages.map(\.id))
    let older = notificationPayload(offset: -864_000)
    try check(notificationStore.applyBackendPage(BackendMailPage(messages: [older], nextCursor: "bootstrap-two", hasMore: false), identity: first),
              "later bootstrap history advances the cursor")
    try check(notificationStore.backendNotificationCandidates(for: first, excluding: firstPageIDs).isEmpty,
              "a nonempty cursor does not turn paginated historical imports into new mail notifications")

    let afterReopen = MailStore(messages: [], persistenceURL: notificationURL)
    afterReopen.backendSyncCursors[first.localID] = nil
    try check(afterReopen.prepareBackendNotifications(for: first, now: cutoff.addingTimeInterval(172_800))
              && afterReopen.backendNotificationCutoffs[first.localID] == cutoff,
              "relaunch and cursor replay preserve the original notification date")
    let knownAfterReopen = Set(afterReopen.messages.map(\.id))
    let arrivedWhileClosed = notificationPayload(offset: 86_400)
    let laterHistoricalImport = notificationPayload(offset: -1_728_000)
    try check(afterReopen.applyBackendPage(BackendMailPage(messages: [historical, arrivedWhileClosed, laterHistoricalImport], nextCursor: "replayed", hasMore: false), identity: first),
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
    try check(queueStore.applyBackendPage(earlyPage, identity: first), "early server Sent metadata and cursor persist together")
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
