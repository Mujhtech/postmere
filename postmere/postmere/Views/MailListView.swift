import SwiftUI

struct MailListView: View {
    @Bindable var store: MailStore
    @Environment(MailRuntime.self) private var runtime
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.postmereAccent) private var accent
    var listFocusRequest = 0
    @FocusState private var isListFocused: Bool
    @State private var showsViewEditor = false
    @State private var scheduleTarget: MailMessage?
    @State private var schedulePurpose: MailSchedulePurpose = .snooze
    @State private var noteTarget: MailMessage?
    @State private var showsInboxManager = false
    @State private var showsProviderSearch = false
    @State private var loadedPage: (scope: MailboxViewScope, limit: Int)?
    private let pageSize = 128

    private func selection(in scope: MailboxViewScope) -> Binding<Set<UUID>> {
        Binding(get: { store.selectedMessageIDs }, set: { store.setSelection($0, in: scope) })
    }

    @State private var showsAction = false

    private var query: String { store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasMessageFilters: Bool { store.unreadOnly || store.attachmentsOnly }
    private var searchesAllMailboxes: Bool { store.searchesAllMailboxes }
    private var mailboxTitle: String {
        if let view = store.selectedSavedView { return view.name }
        if store.selectedMailbox == .inbox,
           let split = store.inboxSplits.first(where: { $0.id == store.selectedInboxSplitID && !$0.isHidden }) { return split.name }
        if let account = store.selectedAccount { return "\(MailAccount.scopeLabel(for: account)) \(store.selectedMailbox.title)" }
        return store.selectedMailbox == .inbox ? "All Inboxes" : store.selectedMailbox.title
    }
    private var searchLocation: String {
        searchesAllMailboxes ? store.selectedAccount.map { "all \(MailAccount.scopeLabel(for: $0)) mailboxes" } ?? "all mailboxes" : mailboxTitle
    }
    private var activeFilterNames: String {
        [store.unreadOnly ? "Unread" : nil, store.attachmentsOnly ? "Attachments" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let current = store.mailboxViewData
        let loadingMailbox = !store.isSearchActive && current == nil
        let mailbox = current ?? store.previousInboxTabForLayout
        let visible = store.isSearchActive ? store.activeSearchResults : mailbox?.messages ?? []
        let counts = store.isSearchActive ? store.searchConversationCounts : mailbox?.conversationCounts ?? [:]
        let scope = store.mailboxViewKey.scope
        let pageLimit = loadedPage.flatMap { $0.scope == scope ? $0.limit : nil } ?? pageSize
        let selectedPosition = store.selectedMessageID.flatMap { id in
            store.isSearchActive ? visible.firstIndex { $0.id == id } : mailbox?.rowPositions[id]
        }
        let limit = max(pageLimit, (selectedPosition ?? -1) + 1)
        VStack(spacing: 0) {
            if store.isSearchActive {
                MailSearchRefinements(store: store, canSearchOnline: runtime.backend.isConnected,
                                      onSaveView: { showsViewEditor = true },
                                      onSearchOnline: { showsProviderSearch = true })
                Divider()
            } else if store.selectedMailbox == .inbox && store.selectedSavedView == nil {
                InboxTabsView(store: store) { showsInboxManager = true }
                    .padding(.top, 12)
                Divider()
            }
            if store.selectedMessageIDs.count > 1 {
                bulkControls
                Divider()
            }

            if store.isSearchActive && !store.hasSearchCriteria {
                Text("Enter a search or choose a filter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                Spacer()
            } else if (loadingMailbox || store.isSearchingMessages) && visible.isEmpty {
                ProgressView(loadingMailbox ? "Loading messages…" : "Searching mail…")
                    .controlSize(.small)
                    .font(.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                emptyState
            } else {
                List(selection: selection(in: mailbox?.key.scope ?? scope)) {
                    if store.isSearchActive {
                        messageRows(visible.prefix(limit), counts: counts)
                    } else if let mailbox {
                        ForEach(mailbox.sections.prefix { $0.offset < limit }) { section in
                            Section(section.id) { messageRows(section.messages.prefix(limit - section.offset), counts: counts) }
                        }
                    }
                    if limit < visible.count {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Loading more messages")
                            .onAppear {
                                if !loadingMailbox { loadedPage = (scope, min(limit + pageSize, visible.count)) }
                            }
                            .id(limit)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count > 1 {
                        bulkActions(for: ids)
                    } else if let id = ids.first, let message = visible.first(where: { $0.id == id }) {
                        messageActions(message)
                    }
                }
                .background { MessageMenuAccent(accent: accent).accessibilityHidden(true) }
                .focused($isListFocused)
                .accessibilityLabel("Messages in \(searchLocation)")
                .onDeleteCommand {
                    guard !loadingMailbox else { return }
                    store.moveMessages(store.selectedMessageIDs, to: .trash)
                }
                .onCommand(#selector(NSResponder.selectAll(_:))) {
                    guard !loadingMailbox else { return }
                    selectAll(visible, in: scope)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didSendActionNotification)) { note in
                    // The native outline view can handle Edit > Select All before SwiftUI's command.
                    guard !loadingMailbox, limit < visible.count, isListFocused,
                          let item = note.userInfo?["MenuItem"] as? NSMenuItem,
                          item.action == #selector(NSResponder.selectAll(_:)) else { return }
                    selectAll(visible, in: scope)
                }
                .onKeyPress(phases: [.down, .repeat], action: handleListKey)
                .allowsHitTesting(!loadingMailbox)
                .accessibilityHidden(loadingMailbox)
                .overlay {
                    if loadingMailbox {
                        ProgressView("Loading messages…").controlSize(.small).font(.callout)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showsAction, let action = store.lastAction {
                HStack(spacing: 10) {
                    Text(action).lineLimit(2)
                    if store.lastActionOffersUndo {
                        Button("Undo", action: store.undoLastMove)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
            }
        }
        .task(id: store.isSearchActive ? nil : store.mailboxViewKey) { await store.loadMailboxView() }
        .task(id: store.actionRevision) {
            showsAction = store.lastAction != nil
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { showsAction = false }
        }
        .defaultFocus($isListFocused, true)
        .navigationTitle(store.isSearchActive ? "Search" : mailboxTitle)
        .navigationSubtitle(loadingMailbox ? "" : subtitle(count: visible.count))
        .toolbar {
            if !store.isSearchActive {
                ToolbarItem(placement: .automatic) {
                    filterMenu
                }
            }
        }
        .onChange(of: listFocusRequest) { isListFocused = true }
        .sheet(isPresented: $showsViewEditor) { SavedInboxViewEditor(store: store, editing: store.isSearchActive ? nil : store.selectedSavedView) }
        .sheet(isPresented: $showsInboxManager) { InboxManagementView(store: store) }
        .sheet(isPresented: $showsProviderSearch) { ProviderSearchView(runtime: runtime) }
        .sheet(item: $scheduleTarget) { message in
            MailScheduleSheet(purpose: schedulePurpose) { date, onlyIfNoReply in
                if schedulePurpose == .snooze { store.snoozeMessage(message.id, until: date) }
                else { store.setFollowUp(message.id, at: date, onlyIfNoReply: onlyIfNoReply) }
            }
        }
        .sheet(item: $noteTarget) { message in PrivateNoteSheet(store: store, message: message) }
    }

    private func messageRows(_ messages: ArraySlice<MailMessage>, counts: [UUID: Int]) -> some View {
        // Reuse the native row at each position when changing tabs. Selection and actions still use the message ID.
        ForEach(0..<messages.count, id: \.self) { offset in
            let index = messages.startIndex + offset
            let message = messages[index]
            let selected = store.selectedMessageIDs.contains(message.id)
            MailRow(message: message, verifiedSenderMark: store.displayedSenderMark(for: message), conversationCount: counts[message.id] ?? 1,
                    location: resultLocation(for: message), showsReplyRequest: store.selectedMailbox == .needsReply, showsSearchDate: store.isSearchActive,
                    outgoingItem: store.outgoingQueue.first { $0.id == message.id },
                    isSelected: selected)
                .mailSelection(selected,
                               joinsAbove: selected && index > messages.startIndex && store.selectedMessageIDs.contains(messages[index - 1].id),
                               joinsBelow: selected && index + 1 < messages.endIndex && store.selectedMessageIDs.contains(messages[index + 1].id))
                .tag(message.id)
                .listRowInsets(EdgeInsets(top: 11, leading: 10, bottom: 11, trailing: 10))
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if message.mailbox == .drafts {
                        Button("Edit Draft", systemImage: "square.and.pencil") { store.beginEditingDraft(message) }
                            .tint(accent.accent)
                    } else if message.mailbox != .outbox && !message.isDraft {
                        Button(message.isUnread ? "Mark as Read" : "Mark as Unread",
                               systemImage: message.isUnread ? "envelope.open" : "envelope.badge") {
                            store.setRead(message.isUnread, for: [message.id])
                        }
                        .tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    trailingSwipeAction(for: message)
                }
        }
    }

    @ViewBuilder
    private func trailingSwipeAction(for message: MailMessage) -> some View {
        switch message.mailbox {
        case .outbox:
            EmptyView()
        case .trash:
            Button("Restore to \(store.restoreDestination(for: message).title)", systemImage: "arrow.uturn.backward") {
                store.restoreMessage(message.id)
            }
            .tint(accent.accent)
        case .drafts:
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                store.moveMessage(message.id, to: .trash)
            }
        default:
            let returnToInbox = message.mailbox == .archive || message.mailbox == .junk
            Button(returnToInbox ? "Move to Inbox" : "Archive",
                   systemImage: returnToInbox ? "tray.and.arrow.down" : "archivebox") {
                store.moveMessage(message.id, to: returnToInbox ? .inbox : .archive)
            }
            .tint(accent.accent)
        }
    }

    private func selectAll(_ messages: [MailMessage], in scope: MailboxViewScope) {
        guard scope == store.mailboxViewKey.scope else { return }
        loadedPage = (scope, messages.count)
        store.setSelection(Set(messages.map(\.id)), in: scope)
    }

    private func resultLocation(for message: MailMessage) -> String? {
        guard searchesAllMailboxes else { return nil }
        if store.selectedAccount == nil && MailAccount.allCases.count > 1 {
            return "\(message.accountLabel) · \(message.mailbox.title)"
        }
        return message.mailbox == store.selectedMailbox ? nil : message.mailbox.title
    }

    private func subtitle(count: Int) -> String {
        if store.isSearchActive {
            return store.hasSearchCriteria && (!store.isSearchingMessages || count > 0) ? "\(count.formatted()) found" : ""
        }
        return count == 1 ? "1 message" : "\(count.formatted()) messages"
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Unread only", isOn: $store.unreadOnly)
            Toggle("With attachments", isOn: $store.attachmentsOnly)
            if hasMessageFilters {
                Divider()
                Button("Clear Filters", action: clearMessageFilters)
            }
            Divider()
            Button(store.selectedSavedView == nil ? "Save Inbox View…" : "Edit Saved View…") { showsViewEditor = true }
            Button("Manage Inbox Tabs and VIPs…") { showsInboxManager = true }
        } label: {
            PostmereLabel("Filter messages", symbol: hasMessageFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", size: 16)
                .labelStyle(.iconOnly)
                .foregroundStyle(hasMessageFilters ? accent.accentInk : PostmereTheme.icon)
        }
        .menuIndicator(.hidden)
        .tint(hasMessageFilters ? accent.accentInk : PostmereTheme.icon)
        .help(hasMessageFilters ? "Filtering: \(activeFilterNames)" : "Filter messages")
        .accessibilityLabel("Filter messages")
        .accessibilityValue(hasMessageFilters ? activeFilterNames : "No filters")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            PostmereLabel.emptyState(emptyTitle, symbol: query.isEmpty ? store.selectedMailbox.systemImage : "magnifyingglass", size: 40)
        } description: {
            Text(emptyDescription)
        } actions: {
            VStack(spacing: 8) {
                if !query.isEmpty {
                    if store.searchScope == .currentMailbox {
                        Button("Search All Mailboxes") { store.searchScope = .allMailboxes }
                    }
                    Button("Clear Search") { store.updateSearchText("") }
                } else if hasMessageFilters {
                    Button("Show All Messages", action: clearMessageFilters)
                } else if !MailAccount.allCases.isEmpty && MailAccount.sendingAccounts.isEmpty {
                    AccountSettingsButton(title: "Reconnect an Account")
                } else if store.selectedMailbox == .drafts && !MailAccount.sendingAccounts.isEmpty {
                    Button("New Message") { store.beginCompose() }
                }
            }
        }
        .controlSize(.small)
        .frame(maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !store.searchIssues.isEmpty { return "Check your search" }
        if !query.isEmpty { return "No results" }
        if store.unreadOnly && !store.attachmentsOnly { return "No unread messages" }
        if hasMessageFilters { return "No matching messages" }
        if store.selectedSavedView != nil { return "No matching messages" }
        switch store.selectedMailbox {
        case .inbox: return "Inbox is empty"
        case .starred: return "No starred messages"
        case .drafts: return "No drafts"
        case .sent: return "No sent messages"
        case .archive: return "No archived messages"
        case .junk: return "Junk is empty"
        case .trash: return "Trash is empty"
        case .needsReply: return "Nothing needs a reply"
        case .snoozed: return "No snoozed messages"
        case .followUps: return "No follow-ups"
        case .newSenders: return "No new senders"
        case .outbox: return "Outbox is empty"
        }
    }

    private var emptyDescription: String {
        if let issue = store.searchIssues.first { return issue.message }
        if !query.isEmpty { return "No messages match “\(query)” in \(searchLocation). Try another search or adjust your filters." }
        if hasMessageFilters { return "No messages in \(mailboxTitle) match your filters." }
        if store.selectedSavedView != nil { return "Messages that match this view’s rules will appear here." }
        switch store.selectedMailbox {
        case .inbox: return "Messages in this inbox will appear here."
        case .starred: return "Star a message to keep it close at hand."
        case .drafts: return "Start a message and save it to finish later."
        case .sent: return "Messages you send will appear here."
        case .archive: return "Archived messages stay available without filling your inbox."
        case .junk: return "Messages your mail provider marks as junk appear here."
        case .trash: return "Messages you move to Trash will appear here."
        case .needsReply: return "Mark a conversation as Needs Reply to keep it here until you answer."
        case .snoozed: return "Snooze a conversation to bring it back at a better time."
        case .followUps: return "Set a reminder on a conversation you want to revisit."
        case .newSenders: return store.senderScreeningEnabled ? "New senders will wait here for your decision." : "Turn on sender screening in Settings to review unfamiliar senders."
        case .outbox: return "Queued and scheduled messages will appear here until they’re sent."
        }
    }

    private func clearMessageFilters() {
        store.unreadOnly = false
        store.attachmentsOnly = false
    }

    @ViewBuilder
    private func messageActions(_ message: MailMessage) -> some View {
        if message.mailbox == .outbox {
            if let item = store.outgoingQueue.first(where: { $0.id == message.id }) {
                if item.status == .failed { Button("Retry Send") { store.retrySend(item.id) } }
                if item.status == .pending && item.undoUntil > .now {
                    Button("Undo Send") { store.undoSend(item.id) }
                }
                Button("Cancel Send and Edit") { store.cancelQueuedSend(item.id) }
                    .disabled(item.status == .delivering)
            }
        } else {
        if message.mailbox == .trash {
            Button("Restore to \(store.restoreDestination(for: message).title)") { store.restoreMessage(message.id) }
            Divider()
        }
        if message.mailbox == .drafts {
            Button("Edit Draft") { store.beginEditingDraft(message) }
        } else {
            Button("Reply") { store.beginCompose(replyTo: message) }
                .disabled(message.isDraft || MailAccount.sendingAccounts.isEmpty)
            Button("Reply All") { store.beginReplyAll(message) }
                .disabled(message.isDraft || MailAccount.sendingAccounts.isEmpty || !store.hasReplyAllRecipients(for: message))
            Button("Forward") { store.beginForward(message) }
                .disabled(message.isDraft || MailAccount.sendingAccounts.isEmpty)
        }
        Divider()
        Button(message.isUnread ? "Mark as Read" : "Mark as Unread") { store.toggleRead(message.id) }
        Button(message.isStarred ? "Remove Star" : "Star Message") { store.toggleStar(message.id) }
        if message.allowsWorkflowActions && message.mailbox != .trash {
            Divider()
            Button(message.workflow.needsReply ? "Mark Done" : "Needs Reply") { store.setNeedsReply(!message.workflow.needsReply, for: message.id) }
            if message.workflow.snoozedUntil != nil {
                Button("Return to Inbox") { store.unsnoozeMessage(message.id) }
            } else {
                Button("Snooze…") { schedulePurpose = .snooze; scheduleTarget = message }
            }
            Button("Follow-up Reminder…") { schedulePurpose = .followUp; scheduleTarget = message }
            if message.workflow.followUpAt != nil {
                Button("Clear Follow-up") { store.clearFollowUp(message.id) }
            }
            Button(message.workflow.privateNote.isEmpty ? "Add Private Note…" : "Edit Private Note…") { noteTarget = message }
            if message.workflow.screeningState == .pending {
                Menu("Accept Sender") {
                    ForEach([SenderRoute.inbox, .archive, .needsReply]) { route in
                        Button(route.title) { store.acceptSender(of: message, route: route) }
                    }
                }
                Button("Block Sender") { store.blockSender(of: message) }
            }
        }
        Divider()
        if !message.isDraft {
            Menu("Move To") {
                ForEach([Mailbox.inbox, .archive]) { mailbox in
                    Button { store.moveMessage(message.id, to: mailbox) } label: {
                        PostmereLabel(mailbox.title, symbol: mailbox.systemImage, size: 14)
                    }
                    .disabled(!store.canMoveMessage(message, to: mailbox))
                }
            }
        }
        Button("Move to Trash", role: .destructive) { store.moveMessage(message.id, to: .trash) }
            .disabled(!store.canMoveMessage(message, to: .trash))
        }
    }

    private var bulkControls: some View {
        HStack(spacing: 10) {
            Text("\(store.selectedMessageIDs.count) selected").foregroundStyle(.secondary)
            Spacer()
            Button { store.moveMessages(store.selectedMessageIDs, to: .archive) } label: { PostmereIcon("archivebox", size: 14) }
                .help("Archive selected messages")
                .accessibilityLabel("Archive selected messages")
            Button { store.moveMessages(store.selectedMessageIDs, to: .trash) } label: { PostmereIcon("trash", size: 14) }
                .help("Move selected messages to Trash")
                .accessibilityLabel("Move selected messages to Trash")
            Menu { bulkActions(for: store.selectedMessageIDs) } label: { PostmereIcon("ellipsis.circle", size: 14) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More actions for selected messages")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func bulkActions(for ids: Set<UUID>) -> some View {
        Button("Archive Selected") { store.moveMessages(ids, to: .archive) }
        Button("Move Selected to Trash", role: .destructive) { store.moveMessages(ids, to: .trash) }
        Divider()
        Button("Mark as Read") { store.setRead(true, for: ids) }
        Button("Mark as Unread") { store.setRead(false, for: ids) }
        Button("Star Selected") { store.setStarred(true, for: ids) }
        Button("Remove Stars") { store.setStarred(false, for: ids) }
        Divider()
        Button("Needs Reply") { store.setNeedsReply(true, for: ids) }
            .disabled(store.selectedMailbox == .junk && !searchesAllMailboxes)
        Button("Mark Done") { store.setNeedsReply(false, for: ids) }
            .disabled(store.selectedMailbox == .junk && !searchesAllMailboxes)
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        guard isListFocused,
              store.isSearchActive || store.mailboxViewData != nil,
              press.modifiers.isEmpty || (press.characters == "#" && press.modifiers == .shift) else { return .ignored }
        if press.key == .escape, store.isSearchActive {
            store.endSearch()
            return .handled
        }
        switch press.characters.lowercased() {
        case "j": store.selectAdjacent(1)
        case "k": store.selectAdjacent(-1)
        case "e": store.moveMessages(store.selectedMessageIDs, to: .archive)
        case "#": store.moveMessages(store.selectedMessageIDs, to: .trash)
        case "s": store.setStarred(!store.selectedMessages.allSatisfy(\.isStarred), for: store.selectedMessageIDs)
        case "r":
            guard store.selectedMessageIDs.count == 1, let message = store.selectedMessage, message.mailbox != .outbox else { return .ignored }
            if message.mailbox == .drafts { store.beginEditingDraft(message) }
            else {
                guard !MailAccount.sendingAccounts.isEmpty else { return .ignored }
                store.beginCompose(replyTo: message)
            }
        default: return .ignored
        }
        return .handled
    }
}

private struct MailRow: View {
    let message: MailMessage
    let verifiedSenderMark: MailVerifiedSenderMark?
    let conversationCount: Int
    var location: String?
    var showsSearchDate = false
    var outgoingItem: OutgoingMailItem?
    var isSelected = false
    @Environment(\.postmereAccent) private var accent
    @AppStorage("showMessagePreviews") private var showMessagePreviews = true

    private var senderTitle: String {
        guard message.isOutgoing else { return message.sender }
        let recipients = message.toRecipients.joined(separator: ", ")
        return recipients.isEmpty ? "No recipient" : "To: \(recipients)"
    }

    private var secondaryForeground: AnyShapeStyle {
        isSelected ? AnyShapeStyle(accent.selectionSecondaryInk) : AnyShapeStyle(.secondary)
    }
    private var indicatorForeground: AnyShapeStyle {
        isSelected ? AnyShapeStyle(accent.selectionInk) : AnyShapeStyle(PostmereTheme.icon)
    }
    private var unreadFill: AnyShapeStyle {
        guard message.isUnread else { return AnyShapeStyle(Color.clear) }
        return AnyShapeStyle(isSelected ? accent.selectionInk : accent.accentInk)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            MailParticipantAvatar(address: message.isOutgoing ? message.toRecipients.first ?? message.senderEmail : message.senderEmail,
                                  name: message.isOutgoing ? "" : message.sender, size: 28, messageID: message.id, verifiedMark: verifiedSenderMark)
                .overlay(alignment: .bottomTrailing) {
                    if message.isUnread {
                        Circle().fill(unreadFill).frame(width: 7, height: 7)
                            .overlay { Circle().stroke(.background, lineWidth: 1) }
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(senderTitle)
                        .font(.system(size: 13, weight: message.isUnread ? .semibold : .medium))
                        .lineLimit(1)
                    if conversationCount > 1 {
                        Text(conversationCount, format: .number)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(secondaryForeground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.clear : PostmereTheme.subtleFill, in: Capsule())
                            .fixedSize()
                            .help("\(conversationCount) messages in conversation")
                            .accessibilityLabel("\(conversationCount) messages in conversation")
                    }
                    Spacer(minLength: 8)
                    Text(showsSearchDate && !Calendar.current.isDateInToday(message.sentAt)
                         ? message.sentAt.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits)) : message.timeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryForeground)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Text(message.displaySubject)
                            .font(.system(size: 12, weight: message.isUnread ? .medium : .regular))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if message.isStarred || !message.attachments.isEmpty { messageIndicators }
                    }
                    if showMessagePreviews {
                        MailVerificationCodeView(message: message, compact: true) {
                            let preview = showsReplyRequest ? (message.replyRequestText ?? message.displayPreview) : message.displayPreview
                            if !preview.isEmpty {
                                Text(verbatim: preview)
                                    .font(.system(size: 12))
                                    .foregroundStyle(secondaryForeground)
                                    .lineSpacing(2)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                if let location {
                    Text(location)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryForeground)
                        .lineLimit(1)
                }
                workflowLabel
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(messageState)
    }

    private var messageIndicators: some View {
        HStack(spacing: 5) {
            if message.isStarred { PostmereIcon("star.fill", size: 11) }
            if !message.attachments.isEmpty { PostmereIcon("paperclip", size: 11) }
        }
        .font(.system(size: 11, weight: .regular))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(indicatorForeground)
        .fixedSize()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var workflowLabel: some View {
        Group {
            if let item = outgoingItem {
                switch item.status {
                case .failed:
                    PostmereLabel("Delivery failed", symbol: "exclamationmark.circle", size: 11)
                        .foregroundStyle(isSelected ? accent.selectionInk : .red)
                        .help(item.lastError ?? "Open Outbox to retry or edit this message")
                case .delivering: PostmereLabel("Sending…", symbol: "paperplane", size: 11)
                case .pending:
                    PostmereLabel("Scheduled \(item.scheduledAt.formatted(date: .abbreviated, time: .shortened))", symbol: "clock", size: 11)
                }
            } else if let date = message.workflow.snoozedUntil {
                PostmereLabel("Until \(date.formatted(date: .abbreviated, time: .shortened))", symbol: "moon.zzz", size: 11)
            } else if message.workflow.screeningState == .pending {
                PostmereLabel("New sender", symbol: "person.crop.circle.badge.questionmark", size: 11)
            } else if let date = message.workflow.followUpAt {
                PostmereLabel("Follow up \(date.formatted(date: .abbreviated, time: .shortened))", symbol: "bell", size: 11)
            } else if message.workflow.needsReply {
                PostmereLabel("Needs reply", symbol: "arrowshape.turn.up.left", size: 11)
            } else if !message.workflow.privateNote.isEmpty {
                PostmereLabel("Private note", symbol: "note.text", size: 11)
            }
        }
        .font(.system(size: 11, weight: .regular))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(secondaryForeground)
        .lineLimit(1)
    }

    private var messageState: String {
        var descriptions = [message.isUnread ? "Unread" : "Read"]
        if message.isStarred { descriptions.append("Starred") }
        if !message.attachments.isEmpty {
            let names = message.attachments.map(\.name).joined(separator: ", ")
            descriptions.append(message.attachments.count == 1 ? "Attachment: \(names)" : "\(message.attachments.count) attachments: \(names)")
        }
        return descriptions.joined(separator: ", ")
    }
}
