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
    earlier.backendMessageID = UUID()
    earlier.providerMessageID = "earlier-message"
    earlier.sentAt = needsReply.sentAt.addingTimeInterval(-60)
    var reminder = one
    reminder.id = UUID()
    reminder.backendMessageID = UUID()
    reminder.providerMessageID = "follow-up-message"
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
    try checkVerificationCodes(identity: first)
    try await checkVerifiedSenderMarks(message: one, identity: first, other: second)
    try await checkDuplicateDeliveries(payload, identity: first, other: second, directory: directory)
    try check(one.id != two.id && one.conversationID != two.conversationID, "identical server IDs remain isolated across server identities")
    let calendarBytes = Data("BEGIN:VCALENDAR\r\nSUMMARY:Design review\r\nEND:VCALENDAR".utf8)
    var calendarFile = BackendAttachment(id: UUID(), filename: "meeting", mimeType: "text/calendar; method=REQUEST",
                                         sizeBytes: calendarBytes.count, providerAttachmentId: nil)
    calendarFile.inlineDataBase64 = calendarBytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
    let localCalendar = calendarFile.localAttachment(messageID: messageID, email: first.email)
    try check(localCalendar.isCalendarFile && localCalendar.inlineCalendarData == calendarBytes,
              "unnamed inline calendar alternatives are available offline in the native cache")
    let stateURL = directory.appendingPathComponent("remote-state.json")
    let store = MailStore(messages: [two], persistenceURL: stateURL)
    let page = BackendMailPage(messages: [payload], nextCursor: "cursor-one", hasMore: false)
    try check(await store.applyBackendPage(page, identity: first), "remote page and cursor persist successfully")
    store.selectedMessageID = one.id
    await store.loadMailboxView()
    let quietRevision = store.mailboxDataRevision, quietSave = store.saveRevision
    let quiet = BackendMailPage(messages: [], nextCursor: "cursor-one", hasMore: false)
    try check(await store.applyBackendPage(quiet, identity: first), "an empty incremental poll completes")
    try check(await store.applyBackendPage(page, identity: first) && store.mailboxDataRevision == quietRevision
              && store.saveRevision == quietSave && store.selectedMessageIDs == [one.id]
              && store.mailboxViewData?.key.messageRevision == quietRevision,
              "empty polls and identical deliveries preserve painted rows, selection and the durable snapshot")
    let reopened = MailStore(messages: [], persistenceURL: stateURL)
    try check(reopened.backendSyncCursors[first.localID] == "cursor-one" && reopened.messages.contains { $0.id == one.id }, "remote cursor never outruns its durable messages")
    let deleted = BackendMailPage(messages: [], nextCursor: "cursor-two", hasMore: false, deletedMessageIds: [messageID])
    try check(await store.applyBackendPage(deleted, identity: first), "explicit provider deletion page persists")
    let deletionRevision = store.mailboxDataRevision, deletionSave = store.saveRevision
    try check(await store.applyBackendPage(deleted, identity: first) && store.mailboxDataRevision == deletionRevision
              && store.saveRevision == deletionSave, "replayed tombstones skip mailbox and disk updates")
    let advance = BackendMailPage(messages: [], nextCursor: "cursor-three", hasMore: false)
    try check(await store.applyBackendPage(advance, identity: first) && store.mailboxDataRevision == deletionRevision
              && store.saveRevision == deletionSave + 1
              && MailStore(messages: [], persistenceURL: stateURL).backendSyncCursors[first.localID] == "cursor-three",
              "an advancing empty page persists its cursor without rebuilding rows")
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

    func labels(_ ids: [String], categories: [String]?) -> BackendMailMessage {
        var row = BackendMailMessage(id: messageID, accountId: accountID, providerMessageId: payload.providerMessageId,
            providerThreadId: payload.providerThreadId, subject: "Label order", from: payload.from, to: [], cc: [], bcc: [],
            textBody: "Updated body", htmlBody: nil, preview: "Updated body", sentAt: payload.sentAt, isRead: true,
            isStarred: false, mailbox: "inbox", providerLabels: ids, attachments: [], listUnsubscribe: [], listUnsubscribePost: [])
        row.categories = categories
        return row
    }
    let labelStore = MailStore(messages: [one])
    let beforeFirstEdit = labelStore.beginProviderPage(for: first.localID)
    labelStore.applyProviderLabels(labels(["Project"], categories: ["Blue"]), messageID: one.id, account: first)
    let beforeSecondEdit = labelStore.beginProviderPage(for: first.localID)
    labelStore.applyProviderLabels(labels(["Project", "Review"], categories: ["Orange"]), messageID: one.id, account: first)
    let staleLabelPage = BackendMailPage(messages: [labels([], categories: nil)], nextCursor: nil, hasMore: false)
    try check(await labelStore.applyBackendPage(staleLabelPage, identity: first, read: beforeFirstEdit)
              && labelStore.messages.first?.providerLabelIDs == ["Project", "Review"]
              && labelStore.messages.first?.providerCategories == ["Orange"]
              && labelStore.messages.first?.preview == "Updated body",
              "an earlier page preserves multiple confirmed label/category edits while applying other message updates")
    labelStore.endProviderPage(beforeFirstEdit)
    let newer = BackendMailPage(messages: [labels(["External"], categories: [])], nextCursor: nil, hasMore: false)
    try check(await labelStore.applyBackendPage(newer, identity: first)
              && labelStore.messages.first?.providerLabelIDs == ["External"] && labelStore.messages.first?.providerCategories == [],
              "a fetch started after label editing accepts later remote label and category changes")
    try check(await labelStore.applyBackendPage(staleLabelPage, identity: first, read: beforeSecondEdit)
              && labelStore.messages.first?.providerLabelIDs == ["External"] && labelStore.messages.first?.providerCategories == [],
              "out-of-order older responses cannot overwrite a newer remote label result")
    labelStore.endProviderPage(beforeSecondEdit)
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
    var arrivals: [MailMessage] = []
    let bootstrap = BackendMailPage(messages: [historical, arrivedDuringSetup, arrivedDuringSetup], nextCursor: "bootstrap-one", hasMore: true)
    try check(await notificationStore.applyBackendPage(bootstrap, identity: first, onArrivals: { arrivals += $0 }),
              "first sync may contain both older mail and a new arrival")
    try check(await notificationStore.applyBackendPage(bootstrap, identity: first, onArrivals: { arrivals += $0 })
              && arrivals.map(\.backendMessageID) == [arrivedDuringSetup.id],
              "initial sync notifies only once for genuine new arrivals across repeated rows and replayed pages")
    arrivals = []
    let older = notificationPayload(offset: -864_000)
    try check(await notificationStore.applyBackendPage(BackendMailPage(messages: [older], nextCursor: "bootstrap-two", hasMore: false),
                                                      identity: first, onArrivals: { arrivals += $0 }),
              "later bootstrap history advances the cursor")
    try check(arrivals.isEmpty,
              "a nonempty cursor does not turn paginated historical imports into new mail notifications")

    let afterReopen = MailStore(messages: [], persistenceURL: notificationURL)
    afterReopen.backendSyncCursors[first.localID] = nil
    try check(await afterReopen.prepareBackendNotifications(for: first, now: cutoff.addingTimeInterval(172_800))
              && afterReopen.backendNotificationCutoffs[first.localID] == cutoff,
              "relaunch and cursor replay preserve the original notification date")
    let arrivedWhileClosed = notificationPayload(offset: 86_400)
    let laterHistoricalImport = notificationPayload(offset: -1_728_000)
    try check(await afterReopen.applyBackendPage(BackendMailPage(messages: [historical, arrivedWhileClosed, laterHistoricalImport], nextCursor: "replayed", hasMore: false),
                                                identity: first, onArrivals: { arrivals += $0 }),
              "cursor replay can contain offline arrivals alongside older history")
    try check(arrivals.map(\.backendMessageID) == [arrivedWhileClosed.id],
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

    let queueFile = directory.appendingPathComponent("remote-queue.json")
    let queueStore = MailStore(messages: [], persistenceURL: queueFile)
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
    let resumedQueue = MailStore(messages: [], persistenceURL: queueFile)
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

@MainActor private func checkVerificationCodes(identity: RemoteAccountIdentity) throws {
    func expect(_ expected: String?, _ description: String, subject: String = "Account notification",
                paragraphs: [String] = [], html: String? = nil) throws {
        let actual = MailVerificationCode.detect(subject: subject, paragraphs: paragraphs, html: html)
        try PostmereBackendRegression.check(actual == expected, description)
    }

    try expect("034091", "a subject-only sign-in code keeps its leading zero", subject: "Your sign-in code is 034091")
    try expect("824931", "a code can precede its verification label", subject: "824931 is your verification code")
    try expect("053804", "Google's G- prefix leaves the six digits ready to enter",
               paragraphs: ["G-053804 is your Google verification code."])
    try expect("571024", "an instruction can place the value after the sign-in action",
               subject: "Sign-in attempt", paragraphs: ["Enter this code to sign in: 571024"])
    try expect("012345", "a temporary verification prompt can put the code on the next line",
               subject: "Your OpenAI code", paragraphs: ["Enter this temporary verification code to continue:\n012345"])
    try expect("012839", "a grouped one-time password copies as a single value",
               paragraphs: ["Your one-time password is 012 839.", "It expires in 10 minutes."])
    try expect("K4R8Q2", "an explicitly identified alphanumeric verification code preserves its characters",
               paragraphs: ["Your verification code: K4R8Q2"])
    try expect("609381", "a security code repeated in the subject and body is unambiguous",
               subject: "Your verification code is 609381", paragraphs: ["Your verification code: 609381"])
    try expect(nil, "conflicting verification codes do not produce a copy action",
               subject: "Your verification code is 123456", paragraphs: ["Your verification code: 654321"])
    try expect(nil, "an order number and a postal code are not verification codes",
               subject: "Receipt for order 349298", paragraphs: ["Your package is on its way to postal code 100001."])
    try expect(nil, "a sign-in footer does not turn a promotional code into a verification code",
               subject: "Sale ends soon", paragraphs: ["Use discount code 847291 at checkout.", "Sign in to your account for early access."])
    try expect(nil, "a hotel booking confirmation is not an account verification code",
               subject: "Your hotel reservation", paragraphs: ["Your confirmation code is K4R8Q2."])
    try expect(nil, "a quoted sign-in email cannot surface an old code",
               paragraphs: ["Thanks for the help.", "On Tuesday, Example wrote:\n> Your sign-in code is 028175."])
    try expect("054291", "a visible code in an HTML table survives entity decoding and formatting",
               html: "<table><tr><td>Your verification code:</td></tr><tr><td><strong>05&#52;291</strong></td></tr></table>")

    // Exercise the provider path too. Cached paragraphs and previews can include
    // text that the reader hides, including earlier replies and preheaders.
    let html = """
        <html><head><title>Your verification code is 311141</title></head><body>
        <div style="display: none">Your verification code is 999999.</div>
        <p>You requested help with your account.</p>
        <a href="https://example.invalid/?verification_code=123456">Visit support</a>
        <blockquote type="cite">Your verification code is 432104.</blockquote>
        </body></html>
        """
    let remote = BackendMailMessage(id: UUID(), accountId: identity.accountID, providerMessageId: "verification-fixture",
        providerThreadId: nil, subject: "Account notification", from: BackendAddress(email: "sender@example.invalid"),
        to: [], cc: [], bcc: [], textBody: "", htmlBody: html, preview: "Your verification code is 999999.",
        sentAt: .now, isRead: false, isStarred: false, mailbox: "inbox", providerLabels: [],
        attachments: [], listUnsubscribe: [], listUnsubscribePost: [])
    let message = remote.localMessage(identity: identity)
    let hiddenCode = MailVerificationCode.detect(subject: message.subject, paragraphs: message.paragraphs,
                                                 html: message.receivedHTML, preview: message.preview)
    try PostmereBackendRegression.check(hiddenCode == nil,
        "HTML metadata, hidden preheaders, URL parameters and quoted codes stay excluded after provider text recovery")
}

@MainActor private func checkReceivedBodyRecovery(_ source: MailMessage, directory: URL) throws {
    let check = PostmereBackendRegression.check
    let html = "<html><head><style>p {color:navy}</style></head><body><p>Alex&#39;s tea &amp; coffee</p><p>Closing invitation</p></body></html>"
    func cached(_ paragraphs: [String], preview: String, html: String?) -> MailMessage {
        var message = source
        message.id = UUID()
        message.backendMessageID = UUID()
        message.providerMessageID = message.id.uuidString
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
