import Foundation

@MainActor
func runSearchSplitRegressions(directory: URL) throws {
    func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        try PostmereBackendRegression.check(condition(), description)
    }
    try runSearchSessionRegressions()
    try runReplyIntentRegressions()
    try runSmartCategoryRegressions()

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
    // Labels match by catalog name (Gmail IDs), by raw ID, or by Outlook category name.
    var labelled = message
    labelled.providerLabelIDs = ["INBOX", "Label_7"]
    labelled.providerCategories = ["Travel"]
    var labelContext = context
    labelContext.labelIDsByName = ["jobs/rejection": ["Label_7"]]
    for source in [MailSearchQuery.labelCondition("Jobs/Rejection"), "label:label_7", "label:travel", "label:\"jobs/rejection\" OR from:nobody"] {
        let query = MailSearchQuery(source: source, calendar: calendar)
        try check(query.isValid && query.matches(labelled, context: labelContext), "label search matches \(source)")
    }
    for source in ["label:Jobs", MailSearchQuery.labelCondition("Jobs/Rejection")] {
        let query = MailSearchQuery(source: source, calendar: calendar)
        try check(query.isValid && !query.matches(message, context: labelContext), "label search excludes unlabelled mail: \(source)")
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
    let either = MailSearchQuery(source: "from:clara OR (subject:review AND is:unread)")
    try check(either.requiredFilterTokens.isEmpty, "an OR branch never activates a whole-search chip")
    let refined = MailSearchQuery(source: either.addingRequiredFilter("is:unread"))
    var read = message
    read.isUnread = false
    try check(either.matches(read) && !refined.matches(read) && refined.matches(message),
              "a quick filter applies to both branches of a typed OR search")
    let required = refined.requiredFilterTokens
    try check(required.count == 1 && required[0].rawText == "is:unread", "only the added global unread chip is selected")
    let restored = MailSearchQuery(source: refined.removingRequiredFilter(required[0]))
    try check(restored.matches(read) && restored.tokens.contains { $0.rawText == "is:unread" },
              "removing a quick filter preserves the user's unread condition inside an OR")
    let negative = MailSearchQuery(source: "NOT (is:unread has:attachment)")
    try check(negative.requiredFilterTokens.isEmpty, "excluded groups leave positive chips inactive")
    let named = #"The "OR" (Studio)\Partners"#
    let quoted = MailSearchQuery(source: MailSearchQuery.senderCondition(named))
    try check(quoted.isValid && quoted.requiredFilterTokens.count == 1 && quoted.tokens[0].value == named,
              "sender filters safely preserve quotes, groups and backslashes as literal names")
    let week = MailSearchQuery(source: "date:this-week", calendar: calendar)
    let interval = calendar.dateInterval(of: .weekOfYear, for: day)!
    var dated = message
    dated.sentAt = interval.start
    try check(week.matches(dated, context: MailSearchContext(referenceDate: day)), "This week includes the local start of the week")
    dated.sentAt = interval.end
    try check(!week.matches(dated, context: MailSearchContext(referenceDate: day))
              && week.matches(dated, context: MailSearchContext(referenceDate: interval.end)),
              "This week uses an exclusive end across DST and advances when reused in a saved search")
    try check(!MailSearchQuery(source: "date:last-century").isValid, "unsupported relative dates are reported")

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
    try check(store.splitMessages(senderSplit.id).count == 1 && store.inboxTabCounts.splits[senderSplit.id] == 1, "tab unread counts deduplicate unread replies in one conversation")
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
    try check(migrated.persistenceError == nil && migrated.inboxSplits.map(\.name) == ["Important", "People", "Purchases", "Subscriptions", "Notifications"]
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

@MainActor
private func runSmartCategoryRegressions() throws {
    func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        try PostmereBackendRegression.check(condition(), description)
    }
    func message(_ subject: String) -> MailMessage {
        MailMessage(sender: "A. Sender", senderEmail: "mailbox@example.com", initials: "AS", subject: subject,
                    preview: "", paragraphs: [], timeLabel: "Now", isUnread: true)
    }

    let receipt = message("Your receipt from Studio")
    let newsletter = message("Fieldnotes weekly digest — November")
    let purchaseQuery = MailSearchQuery(source: "is:purchase")
    let subscriptionQuery = MailSearchQuery(source: "is:subscription")
    for subject in ["Order confirmation", "Invoice #48290", "Your order #A321", "Your order has shipped", "Payment received"] {
        try check(purchaseQuery.matches(message(subject)), "recognizes a purchase: \(subject)")
    }
    for subject in ["Buy now and save", "Save on your next order", "Did you receive my invoice?", "Your guide to invoice automation", "Payment confirmation code", "Re: Your receipt from Studio"] {
        try check(!purchaseQuery.matches(message(subject)), "avoids classifying an offer or a conversation as a purchase")
    }
    var promotion = message("Studio sale")
    promotion.providerLabelIDs = ["CATEGORY_PROMOTIONS"]
    var categorized = message("Download ready")
    categorized.providerCategories = ["Receipts"]
    var list = message("A new edition")
    list.unsubscribeHeaders = MailUnsubscribeHeaders(listUnsubscribe: ["<mailto:leave@example.com>"], listUnsubscribePost: [], authenticationResults: [], dkimSignatures: [], source: "gmail")
    var identifiedList = message("Meeting moved to Friday")
    identifiedList.hasMailingListID = true
    try check(subscriptionQuery.matches(list) && subscriptionQuery.matches(newsletter) && subscriptionQuery.matches(identifiedList),
              "List-ID, unsubscribe headers and newsletter subjects each identify subscriptions")
    try check(!subscriptionQuery.matches(promotion), "an ordinary promotion alone does not imply a subscription")
    try check(categorized.isPurchaseMail && !categorized.isSubscriptionMail, "explicit Outlook receipt category is honored")
    var spam = receipt
    spam.providerLabelIDs = ["SPAM", "CATEGORY_PROMOTIONS"]
    var outgoing = newsletter
    outgoing.isOutgoing = true
    try check(!spam.isSubscriptionMail && !spam.isPurchaseMail && !outgoing.isSubscriptionMail,
              "smart categories exclude outgoing and legacy provider spam")
    let store = MailStore(messages: [receipt, newsletter])
    let purchase = try requireSplit("Purchases", store)
    let subscriptions = try requireSplit("Subscriptions", store)
    try check(store.splitMessages(purchase.id).map(\.id) == [receipt.id] &&
              store.splitMessages(subscriptions.id).map(\.id) == [newsletter.id],
              "specific categories win over the default broad People filter")

    var old = subscriptions
    old.name = "Newsletters"
    old.criteria = SavedInboxCriteria(query: "has:unsubscribe OR category:promotions OR category:forums")
    old.isHidden = true
    let custom = InboxSplit(name: "Studio", criteria: .init(query: "from:studio"))
    let upgraded = InboxSplit.upgradingLegacyTabs([custom, old])
    try check(upgraded.first == custom && upgraded.contains { $0.id == old.id && $0.name == "Subscriptions" && $0.isHidden },
              "legacy Newsletters retains identity, relative order and hidden state")
    old.name = "For later"
    old.criteria = SavedInboxCriteria(query: "from:design")
    let edited = InboxSplit.upgradingLegacyTabs([old])
    try check(edited.contains(old) && edited.contains { $0.name == "Subscriptions" && $0.id != old.id },
              "a user-edited legacy tab stays intact alongside the new category")
    try check(InboxSplit.upgradingLegacyTabs([]).contains { $0.name == "Subscriptions" && $0.isHidden },
              "removing Newsletters before upgrading keeps its successor hidden")

    let oldData = try JSONEncoder().encode(MailStateSnapshot(messages: [], savedViews: [], snippets: [], senderRules: [],
        outgoingQueue: [], activeDraft: nil, senderScreeningEnabled: true, inboxSplits: [old]))
    var json = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
    json.removeValue(forKey: "inboxSplitDefaultsVersion")
    var restored = try JSONDecoder().decode(MailStateSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    try check(restored.inboxSplits.contains { $0.name == "Purchases" }, "a saved legacy tab configuration gains Purchases")
    restored.inboxSplits.removeAll { $0.name == "Purchases" }
    let reopened = try JSONDecoder().decode(MailStateSnapshot.self, from: JSONEncoder().encode(restored))
    try check(!reopened.inboxSplits.contains { $0.name == "Purchases" }, "later launches respect deletion of a migrated tab")
}

@MainActor
private func requireSplit(_ name: String, _ store: MailStore) throws -> InboxSplit {
    let split = store.inboxSplits.first { $0.name == name }
    try PostmereBackendRegression.check(split != nil, "missing default split " + name)
    return split!
}

@MainActor
private func runSearchSessionRegressions() throws {
    func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        try PostmereBackendRegression.check(condition(), description)
    }
    let older = MailMessage(sender: "One", senderEmail: "one@example.org", initials: "O",
                            subject: "Budget memo", preview: "", paragraphs: [], timeLabel: "", isUnread: true,
                            account: "Work", sentAt: Date(timeIntervalSince1970: 100))
    var latest = older
    latest.id = UUID()
    latest.subject = "Budget approvals"
    latest.mailbox = .archive
    latest.sentAt = Date(timeIntervalSince1970: 200)
    var personal = older
    personal.id = UUID()
    personal.account = "Personal"
    let store = MailStore(messages: [older, personal, latest])
    store.selectedAccount = "Work"
    store.unreadOnly = true
    store.selectedMessageID = older.id
    store.beginSearch()
    try check(store.isSearchActive && store.searchScope == .allMailboxes && store.filteredMessages.isEmpty
              && store.selectedMessageID == nil && !store.unreadOnly, "toolbar search starts without selecting a result or inheriting mailbox filters")
    store.updateSearchText("budget")
    try check(store.filteredMessages.map(\.id) == [latest.id, older.id] && store.selectedMessageID == nil,
              "live search spans the active account's mailboxes and orders hits newest first")
    store.selectAdjacent(1)
    try check(store.selectedMessageID == latest.id, "keyboard selection follows displayed search order")
    store.updateSearchText("approvals")
    try check(store.selectedMessageID == latest.id, "refining a query preserves a result that still matches")
    store.searchScope = .currentMailbox
    try check(store.filteredMessages.isEmpty && store.selectedMessageID == nil, "narrowing the scope clears a stale reader")
    store.updateSearchText("is:unread OR from:nobody")
    store.setSelection([older.id])
    try check(store.selectedMessageID == older.id && store.messages.first?.isUnread == true,
              "opening an unread-dependent search result preserves its membership")
    store.updateSearchText("")
    try check(store.isSearchActive && store.selectedMessageID == nil && store.filteredMessages.isEmpty,
              "clearing the query keeps the search field available and clears its results")
    store.endSearch()
    try check(!store.isSearchActive && store.unreadOnly && store.searchScope == .currentMailbox
              && store.selectedMessageID == older.id && store.selectedAccount == "Work", "cancel restores the browsing scope, filter and selection")

    store.updateSearchText("memo")
    store.selectMailbox(.archive)
    store.endSearch()
    try check(!store.isSearchActive && store.searchText.isEmpty && store.selectedMailbox == .archive && store.selectedMessageID == nil,
              "explicit mailbox navigation leaves search and cannot resurrect its old selection")
    store.selectedAccount = nil
    store.select(latest)
    store.beginSearch()
    store.updateSearchText("budget")
    store.setSelection([older.id])
    var revised = store.messages.first { $0.id == older.id }!
    revised.subject = "Minutes"
    revised.conversationID = UUID()
    store.mergeIncoming([revised])
    try check(store.selectedMessageID == nil && !store.filteredMessages.contains { $0.id == older.id },
              "a sync that changes the selected result clears its preview")
    store.endSearch()
    try check(store.selectedMessageID == latest.id, "leaving search after a sync restores a still-visible message")
}

@MainActor
func runBackgroundSearchRegressions() async throws {
    let messages = (0..<180).map { index in
        MailMessage(sender: "Sender", senderEmail: "hi@example.org", initials: "S",
                    subject: index.isMultiple(of: 2) ? "Alpha" : "Beta", preview: "Search fixture",
                    paragraphs: ["Budget review"], timeLabel: "", isUnread: true,
                    sentAt: Date(timeIntervalSince1970: Double(index)))
    }
    let store = MailStore(messages: messages)
    store.updateSearchText("Alpha")
    let obsolete = store.searchTask
    store.updateSearchText("Beta")
    try PostmereBackendRegression.check(store.isSearchingMessages && store.filteredMessages.isEmpty,
                                         "large searches return control before publishing matches")
    await obsolete?.value
    await store.searchTask?.value
    let hits = store.filteredMessages
    try PostmereBackendRegression.check(!store.isSearchingMessages && hits.count == 90 && hits.allSatisfy { $0.subject == "Beta" }
                                         && hits.first?.id == messages.last?.id,
                                         "rapid typing publishes only the latest query in newest-first order")
    store.setSelection([messages.last!.id])
    try PostmereBackendRegression.check(store.selectedMessageID == messages.last!.id && store.filteredMessages.first?.isUnread == false
                                         && !store.isSearchingMessages, "opening a large-search result updates its row without rerunning the query")
    let changedID = store.messages[1].id
    store.messages[1].subject = "Gamma"
    try PostmereBackendRegression.check(store.isSearchingMessages && store.filteredMessages.count == 90
                                         && store.navigableMessages?.first?.id == messages.last?.id,
                                         "same-query sync keeps the existing rows visible and selectable while refreshing")
    await store.searchTask?.value
    try PostmereBackendRegression.check(store.filteredMessages.count == 89 && !store.filteredMessages.contains { $0.id == changedID },
                                         "the completed refresh removes messages that stopped matching")
    store.messages[1].subject = "Beta"
    await store.searchTask?.value
    store.updateSearchText("Alpha")
    try PostmereBackendRegression.check(store.filteredMessages.isEmpty, "a changed query clears the previous query's rows")
    let closing = store.searchTask
    store.endSearch()
    await closing?.value
    try PostmereBackendRegression.check(!store.isSearchActive && !store.isSearchingMessages && store.filteredMessages.count == 180,
                                         "closing a pending query cannot publish stale results over the mailbox")

    let accounts = RemoteAccountRegistry.accounts
    defer { RemoteAccountRegistry.accounts = accounts }
    let identity = RemoteAccountIdentity(localID: "remote:search-fixture", accountID: UUID(), scope: "search-fixture",
                                         email: "search@example.org", displayName: "Search", provider: "gmail")
    RemoteAccountRegistry.accounts = [identity]
    var remote = messages[0]
    remote.account = identity.localID
    let accountStore = MailStore(messages: [remote])
    accountStore.updateSearchText("Alpha")
    try PostmereBackendRegression.check(accountStore.filteredMessages.count == 1, "the connected account can search its cached row")
    RemoteAccountRegistry.accounts = []
    try PostmereBackendRegression.check(accountStore.filteredMessages.isEmpty,
                                         "revoking the active account hides cached hits immediately")
    accountStore.endSearch()
    let alpha = InboxSplit(name: "Alpha", criteria: SavedInboxCriteria(query: "subject:Alpha"))
    let beta = InboxSplit(name: "Beta", criteria: SavedInboxCriteria(query: "subject:Beta"))
    store.inboxSplits = [alpha, beta]
    store.selectInboxSplit(alpha.id)
    let earlier = store.mailboxViewTask
    store.selectInboxSplit(beta.id)
    try PostmereBackendRegression.check(store.selectedInboxSplitID == beta.id && store.mailboxViewData == nil,
                                        "navigating large inbox tabs updates scope before calculating rows")
    await earlier?.value
    await store.loadMailboxView()
    let current = store.mailboxViewData
    try PostmereBackendRegression.check(current?.messages.count == 90 && current?.messages.allSatisfy { $0.subject == "Beta" } == true
                                        && current?.sections.first?.messages.count == 90 && store.selectedMessageID == nil,
                                        "only the latest tab publishes rows and grouping, and it opens on the overview")
    let badges = await store.loadInboxTabCounts()
    try PostmereBackendRegression.check(badges.all == 179 && badges.splits[alpha.id] == 90 && badges.splits[beta.id] == 89,
                                        "independent tab badges use current read state and matching rules")
    let previousScope = store.mailboxViewKey.scope
    store.select(current!.messages[0])
    store.selectInboxSplit(alpha.id)
    let selecting = store.mailboxViewTask
    store.setSelection([], in: previousScope)
    store.selectAdjacent(1)
    try PostmereBackendRegression.check(store.navigableMessages == nil && store.selectedMessageID == nil,
                                        "switching tabs closes the reader; old list callbacks and keyboard navigation wait for the next tab's rows")
    store.select(messages[2])
    await selecting?.value
    await store.loadMailboxView()
    try PostmereBackendRegression.check(store.selectedMessageID == messages[2].id, "a pending tab load preserves a subsequent explicit selection")
    store.setSelection([messages[4].id], in: store.mailboxViewKey.scope)
    store.setSelection([], in: previousScope)
    try PostmereBackendRegression.check(store.selectedMessageID == messages[4].id,
                                        "an old tab cannot clear a newer selection after the replacement rows appear")
    await store.prepareInboxTabs()
    store.selectInboxSplit(beta.id)
    try PostmereBackendRegression.check(store.mailboxViewData?.messages.count == 90
                                        && store.selectedMessageID == nil
                                        && store.startMailboxViewLoad() == nil,
                                        "a prepared tab switches its rows without a second grouping pass and opens on the overview")
    store.messages[0].subject = "Beta"
    store.selectInboxSplit(beta.id)
    await store.loadMailboxView()
    try PostmereBackendRegression.check(store.selectedMessageID == nil && store.mailboxViewData?.messages.count == 91,
                                        "a message update invalidates prepared tabs before the next switch")
    store.selectAccount("Personal")
    try PostmereBackendRegression.check(store.mailboxViewData == nil, "switching accounts hides the previous mailbox snapshot immediately")
    await store.loadMailboxView()
    try PostmereBackendRegression.check(store.mailboxViewData?.messages.isEmpty == true && store.selectedMessageID == nil,
                                        "an empty new account cannot receive another account’s mailbox results")
}

@MainActor
private func runReplyIntentRegressions() throws {
    func message(_ body: String, subject: String = "An update", from: String = "maya@example.com") -> MailMessage {
        MailMessage(sender: "Maya", senderEmail: from, initials: "M", subject: subject,
                    preview: "", paragraphs: [body], timeLabel: "Now", toRecipients: ["alex@example.com"],
                    providerAccountEmail: "alex@example.com")
    }
    func expect(_ input: MailMessage, _ expected: String?, _ reason: String) throws {
        try PostmereBackendRegression.check(MailReplyIntent.request(in: input) == expected, reason)
    }
    let request = "Could you share the revised proof by Thursday?"
    try expect(message("Hi Alex,\n\nThe team is ready. " + request), request, "reply queue quotes the specific current sentence")
    try expect(message("Please confirm the time for tomorrow."), "Please confirm the time for tomorrow.", "imperatives without a question mark can warrant a reply")
    try expect(message("Would Tuesday work for you?"), "Would Tuesday work for you?", "scheduling question")
    try expect(message("Any thoughts on the price?"), "Any thoughts on the price?", "short personal question")
    try expect(message("See attached.", subject: "When are you free?"), "When are you free?", "original actionable subject")
    try expect(message("All sorted.", subject: "Re: When are you free?"), nil, "quoted reply subject is not a fresh ask")
    try expect(message("Thanks.\nOn Monday, Alex wrote:\n" + request), nil, "ignore quoted plaintext reply")
    try expect(message("Here it is.\n-----Original Message-----\n" + request), nil, "ignore Outlook forwarded requests")
    try expect(message("Erledigt.", subject: "AW: " + request), nil, "a localized reply subject does not belong to the new sender")
    try expect(message("Danke.\nAm Montag, den 16. November\nschrieb Alex:\n" + request), nil,
               "a wrapped German reply attribution ends the authored body")
    try expect(message("Danke.\nVon: Alex\nGesendet: Donnerstag\nAn: Maya\nBetreff: Termin\n" + request), nil,
               "an Outlook header block works even when From contains only a display name")
    try expect(message(request + "\n-----Ursprüngliche Nachricht-----\nPlease confirm tomorrow."), request,
               "keep the sender’s own ask above German quoted mail")
    try expect(message(request + " No need to reply."), nil, "explicit response exemption")
    try expect(message("Let me know if you have any questions."), nil, "optional invitation for questions")
    try expect(message("Ready to save? Shop now."), nil, "promotional questions")
    try expect(message(request, from: "no-reply@example.com"), nil, "automated sender")
    try expect(message("Please confirm your email address.", subject: "Your verification code"), nil, "verification notice")
    var list = message(request)
    list.unsubscribeHeaders = MailUnsubscribeHeaders(listUnsubscribe: ["<https://example.com/remove>"], listUnsubscribePost: [], authenticationResults: [], dkimSignatures: [], source: "gmail")
    try expect(list, nil, "list distribution metadata")
    var cc = message(request)
    cc.toRecipients = ["someone@example.com"]
    cc.ccRecipients = ["Alex <ALEX@example.com>"]
    try expect(cc, nil, "request addressed to another recipient")
    var html = message(request)
    html.bodyHTML = "<p>Done.</p><div class='gmail_quote'>" + request + "</div>"
    try expect(html, nil, "flattened HTML quote must not create a request")
    html.bodyHTML = "<p>Danke.</p><div id='x_divRplyFwdMsg'>Von: Alex</div><p>" + request + "</p>"
    try expect(html, nil, "an Outlook reply marker ends the HTML author's content")
    html.bodyHTML = "<p>Done.</p><div hidden>" + request + "</div>"
    try expect(html, nil, "hidden HTML preheader must not create a request")
    html.bodyHTML = "<p>Good morning!</p><p>Could you share the <strong>revised</strong> proof by Thursday?</p>"
    try expect(html, request, "HTML styled across inline elements returns the actual ask")
    var sent = message(request)
    sent.isOutgoing = true
    try expect(sent, nil, "sent questions are not incoming tasks")
}
