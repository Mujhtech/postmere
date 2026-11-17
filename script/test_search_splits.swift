import Foundation

@MainActor
func runSearchSplitRegressions(directory: URL) throws {
    func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        try PostmereBackendRegression.check(condition(), description)
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let day = calendar.date(from: DateComponents(year: 2024, month: 11, day: 3))!
    var message = MailMessage(sender: "Clára Team", senderEmail: "clara@example.com", initials: "C",
        subject: "Design review: phase two", preview: "Ready for review", paragraphs: ["The café plan is ready", "Literal -option, OR, and a \"quote\""],
        timeLabel: "Now", isUnread: true, isStarred: true,
        toRecipients: ["Alex <alex@postmere.app>"], ccRecipients: ["team@example.com"], bccRecipients: ["private@example.com"],
        attachments: [MailAttachment(name: "proposal.PDF", detail: "PDF", mimeType: "application/pdf")], sentAt: day,
        providerLabelIDs: ["CATEGORY_UPDATES"])
    message.workflow.needsReply = true
    let context = MailSearchContext(vipContacts: [VIPContact(value: "example.com", kind: .domain)])
    let successes = [
        "from:clara to:alex subject:\"design review\" has:attachment filetype:pdf is:unread",
        "cc:team bcc:private body:cafe filename:proposal domain:example.com account:Work",
        "is:starred is:needsreply is:incoming is:vip category:updates",
        "subject:missing OR from:clara has:attachment",
        "(from:nobody OR from:clara) -subject:missing",
        "-(subject:missing OR from:nobody)",
        "NOT (from:nobody OR is:outgoing)",
        "body:\"a \\\"quote\\\"\"", "\"-option\"", "\\-option", "\\OR", "\"review: phase\"",
        "after:2024-11-03 before:2024-11-04", "filetype:application/pdf", "filetype:.pdf"
    ]
    for source in successes {
        let query = MailSearchQuery(source: source, calendar: calendar)
        try check(query.isValid && query.matches(message, context: context), "search matches \(source)")
    }
    for source in ["before:2024-11-03", "after:2024-11-04", "from:clara subject:missing OR from:nobody", "-is:starred", "is:outgoing", "is:read", "category:promotions", "filetype:image/*"] {
        let query = MailSearchQuery(source: source, calendar: calendar)
        try check(query.isValid && !query.matches(message, context: context), "search excludes \(source)")
    }
    let malformed = ["from:", "unknown:value", "has:banana", "is:secret", "after:2024-02-30", "before:2024-1-1", "subject:\"unfinished", "()", "(from:clara", "from:clara)", "OR from:clara", "from:clara OR", "from:clara OR OR to:alex", "AND from:clara", "from:clara AND", "NOT", "-", "\"\"", "trailing\\", "filetype:?!"]
    for source in malformed {
        let query = MailSearchQuery(source: source, calendar: calendar)
        try check(!query.isValid && !query.matches(message, context: context) && !query.issues.isEmpty, "invalid search fails closed: \(source)")
    }
    try check(!MailSearchQuery(source: String(repeating: "x", count: 16_385)).isValid, "query length has a bounded validation error")
    try check(!MailSearchQuery(source: String(repeating: "x ", count: 260)).isValid, "query token count is bounded")
    try check(!MailSearchQuery(source: String(repeating: "(", count: 33) + "x" + String(repeating: ")", count: 33)).isValid, "query nesting is bounded")
    try check(MailSearchQuery(source: " \n ").matches(message), "empty query matches all eligible mail")
    try check(!MailSearchQuery(source: "café", defaultField: .subject).matches(message)
              && MailSearchQuery(source: "café", defaultField: .all).matches(message), "plain-text field scope controls the default search field")
    try check(MailSearchQuery(source: "body:cafe", defaultField: .subject).matches(message), "an explicit operator overrides the default field")

    let editable = MailSearchQuery(source: "from:Clára subject:\"review: phase\" OR is:unread")
    let subjectToken = editable.tokens.first { $0.field == "subject" }!
    try check(editable.replacingToken(id: subjectToken.id, with: "has:attachment") == "from:Clára has:attachment OR is:unread", "token replacement preserves Unicode and neighboring syntax")
    for source in ["from:nobody OR from:clara", "from:clara AND from:nobody", "(from:nobody) OR from:clara", "NOT (from:nobody) from:clara", "from:clara OR (from:nobody AND is:unread)"] {
        let query = MailSearchQuery(source: source)
        let token = query.tokens.first { $0.value == "nobody" }!
        let edited = MailSearchQuery(source: query.removingToken(id: token.id))
        try check(edited.isValid && edited.matches(message), "removing a chip repairs its operators and groups: \(source)")
    }
    let lastToken = MailSearchQuery(source: "-from:nobody")
    try check(lastToken.removingToken(id: lastToken.tokens[0].id).isEmpty, "removing the final chip clears search")

    let exactVIP = VIPContact(value: "CLARA@EXAMPLE.COM", kind: .person, account: "Work")
    try check(exactVIP.matches(message), "VIP people match exact case-insensitive sender addresses and account")
    var otherAccount = message
    otherAccount.account = "Personal"
    try check(!exactVIP.matches(otherAccount), "VIP person account scope does not cross accounts")
    var subdomain = message
    subdomain.senderEmail = "clara@team.example.com"
    let domainVIP = VIPContact(value: "example.com", kind: .domain)
    try check(domainVIP.matches(subdomain) && !VIPContact(value: "example.com", kind: .domain, includeSubdomains: false).matches(subdomain), "VIP domains include subdomains only when enabled")
    subdomain.senderEmail = "clara@badexample.com"
    try check(!domainVIP.matches(subdomain), "VIP domain suffix checks respect label boundaries")
    var providerMessage = message
    providerMessage.providerAccountEmail = "one@example.com"
    let scopedVIP = VIPContact(value: "clara@example.com", kind: .person, providerAccountEmail: "two@example.com")
    try check(!scopedVIP.matches(providerMessage), "VIP provider-identity scope remains isolated")
    var outgoing = message
    outgoing.isOutgoing = true
    try check(!domainVIP.matches(outgoing), "VIP status describes incoming senders")

    var reply = message
    reply.id = UUID()
    reply.sender = "Other"
    reply.senderEmail = "other@elsewhere.com"
    reply.isStarred = false
    reply.sentAt = day.addingTimeInterval(60)
    var separate = reply
    separate.id = UUID()
    separate.conversationID = UUID()
    separate.isUnread = false
    var archived = message
    archived.id = UUID()
    archived.conversationID = UUID()
    archived.mailbox = .archive
    let stateURL = directory.appendingPathComponent("search-splits.json")
    let store = MailStore(messages: [message, reply, separate, archived], persistenceURL: stateURL)
    let senderSplit = InboxSplit(name: "Clara", criteria: SavedInboxCriteria(query: "from:clara"))
    let subjectSplit = InboxSplit(name: "Review", criteria: SavedInboxCriteria(query: "subject:review"))
    store.inboxSplits = [senderSplit, subjectSplit]
    try check(store.splitMessages(senderSplit.id).count == 1 && store.splitUnreadCount(senderSplit.id) == 1, "tab unread counts deduplicate unread replies in one conversation")
    try check(store.splitMessages(subjectSplit.id).count == 1 && store.splitMessages(subjectSplit.id)[0].id == separate.id, "first-match assigns a complete conversation to one tab")
    try check(!store.splitMatchReasons(for: reply, splitID: senderSplit.id).isEmpty, "classification explanations include a matching earlier reply")
    store.inboxSplitOverlapPolicy = .allMatches
    try check(store.splitMessages(subjectSplit.id).count == 2, "all-matches includes a conversation in both matching tabs")
    store.inboxSplitOverlapPolicy = .firstMatch
    store.setInboxSplitHidden(senderSplit.id, hidden: true)
    try check(store.splitMessages(subjectSplit.id).count == 2, "hidden tabs do not reserve first-match precedence")
    store.setInboxSplitHidden(senderSplit.id, hidden: false)
    store.moveInboxSplit(id: subjectSplit.id, to: 0)
    try check(store.splitMessages(subjectSplit.id).count == 2 && store.splitMessages(senderSplit.id).isEmpty, "reordering changes first-match precedence deterministically")
    store.moveInboxSplit(id: senderSplit.id, to: 0)
    store.selectInboxSplit(senderSplit.id)
    try check(store.filteredMessages.count == 1, "selecting an inbox tab filters to conversation representatives")
    store.searchText = "from:clara"
    store.searchScope = .allMailboxes
    try check(store.filteredMessages.count == 2 && store.filteredMessages.contains { $0.mailbox == .archive }, "all-mailbox search bypasses an active inbox tab")
    store.searchText = "from:"
    try check(store.filteredMessages.isEmpty && !store.searchIssues.isEmpty, "store search exposes parser errors without widening results")
    store.clearFilters()
    try check(store.saveVIPContact(exactVIP) && store.saveVIPContact(exactVIP) && store.vipContacts.count == 1, "VIP upsert normalizes and avoids duplicates")
    try check(!store.saveVIPContact(VIPContact(value: "https://example.com", kind: .domain)), "VIP validation rejects a URL used as a domain")
    try check(!store.saveInboxSplit(InboxSplit(name: "Bad", criteria: SavedInboxCriteria(query: "from:"))), "invalid split criteria cannot be saved")
    let fieldView = SavedInboxView(name: "Body only", criteria: SavedInboxCriteria(query: "café", mailbox: nil, searchField: .subject))
    store.saveInboxView(fieldView)
    store.selectSavedView(fieldView)
    try check(store.filteredMessages.isEmpty, "saved views use the same search field and parser")
    store.selectInboxSplit(senderSplit.id)
    let reopened = MailStore(messages: [], persistenceURL: stateURL)
    try check(reopened.selectedInboxSplitID == senderSplit.id && reopened.inboxSplits.map(\.id) == store.inboxSplits.map(\.id)
              && reopened.vipContacts == store.vipContacts && reopened.inboxSplitOverlapPolicy == .firstMatch, "split order, selected tab, VIPs and overlap policy survive restart")
    try check(reopened.savedViews.first?.criteria.mailbox == nil && reopened.savedViews.first?.criteria.searchField == .subject, "saved-view all-mailbox scope and search field survive restart")
    reopened.deleteInboxSplit(senderSplit.id)
    try check(reopened.selectedInboxSplitID == nil && !reopened.inboxSplits.contains { $0.id == senderSplit.id }, "deleting the active tab returns safely to All Inbox")

    let legacyURL = directory.appendingPathComponent("legacy-search-state.json")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    for key in ["inboxSplits", "vipContacts", "selectedInboxSplitID", "inboxSplitOverlapPolicy"] { legacy.removeValue(forKey: key) }
    var legacyViews = legacy["savedViews"] as! [[String: Any]]
    var legacyCriteria = legacyViews[0]["criteria"] as! [String: Any]
    legacyCriteria.removeValue(forKey: "searchField")
    legacyCriteria.removeValue(forKey: "mailbox")
    legacyViews[0]["criteria"] = legacyCriteria
    legacy["savedViews"] = legacyViews
    try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
    let migrated = MailStore(messages: [], persistenceURL: legacyURL)
    try check(migrated.persistenceError == nil && migrated.inboxSplits.map(\.name) == ["Important", "People", "Newsletters", "Notifications"]
              && migrated.vipContacts.isEmpty && migrated.selectedInboxSplitID == nil, "legacy snapshots acquire editable default tabs without losing mail")
    try check(migrated.savedViews[0].criteria.searchField == .all && migrated.savedViews[0].criteria.mailbox == nil, "legacy missing search field defaults to All Text and omitted mailbox remains All Mailboxes")
    try check(InboxSplit.defaults.allSatisfy { MailSearchQuery(source: $0.criteria.query).isValid }, "all default tab predicates are valid editable queries")

    let futureOnly = MailStore(messages: [message])
    futureOnly.saveSenderRule(SenderRule(email: message.senderEmail, account: message.account, route: .blocked), applyToExisting: false)
    try check(futureOnly.messages[0].mailbox == .inbox, "future-only sender rules leave existing mail untouched")
    var future = message
    future.id = UUID()
    future.conversationID = UUID()
    futureOnly.mergeIncoming([future])
    try check(futureOnly.messages.first { $0.id == future.id }?.mailbox == .trash, "future-only sender rules apply when later mail arrives")
}
