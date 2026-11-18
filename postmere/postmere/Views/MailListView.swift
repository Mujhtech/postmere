import SwiftUI

struct MailListView: View {
    @Bindable var store: MailStore
    @Environment(MailRuntime.self) private var runtime
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    @State private var showsViewEditor = false
    @State private var scheduleTarget: MailMessage?
    @State private var schedulePurpose: MailSchedulePurpose = .snooze
    @State private var noteTarget: MailMessage?
    @State private var showsInboxManager = false
    @State private var showsSearchHelp = false
    @State private var showsProviderSearch = false

    private var selection: Binding<Set<UUID>> {
        Binding(get: { store.selectedMessageIDs }, set: store.setSelection)
    }

    private var groups: [String] {
        var labels: [String] = []
        for message in store.filteredMessages where !labels.contains(message.dateLabel) {
            labels.append(message.dateLabel)
        }
        return labels
    }

    private var query: String { store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasMessageFilters: Bool { store.unreadOnly || store.attachmentsOnly }
    private var searchesAllMailboxes: Bool { !query.isEmpty && store.searchScope == .allMailboxes }
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
        VStack(spacing: 0) {
            searchControls
            if store.selectedMailbox == .inbox && store.selectedSavedView == nil && !searchesAllMailboxes {
                InboxTabsView(store: store) { showsInboxManager = true }
            }
            filterControls
            Divider()
            if store.selectedMessageIDs.count > 1 {
                bulkControls
                Divider()
            }

            if store.filteredMessages.isEmpty {
                emptyState
            } else {
                List(selection: selection) {
                    ForEach(groups, id: \.self) { group in
                        Section(group) {
                            ForEach(store.filteredMessages.filter { $0.dateLabel == group }) { message in
                                MailRow(message: message, conversationCount: message.isDraft ? 1 : store.conversationCount(for: message), showsLocation: searchesAllMailboxes, outgoingItem: store.outgoingQueue.first { $0.id == message.id }, isSelected: store.selectedMessageIDs.contains(message.id))
                                    .tag(message.id)
                                    .listRowInsets(EdgeInsets(top: 11, leading: 10, bottom: 11, trailing: 10))
                                    .contextMenu {
                                        if store.selectedMessageIDs.contains(message.id) && store.selectedMessageIDs.count > 1 {
                                            bulkActions
                                        } else {
                                            messageActions(message)
                                        }
                                    }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .focused($isListFocused)
                .accessibilityLabel("Messages in \(searchLocation)")
                .onDeleteCommand {
                    store.moveMessages(store.selectedMessageIDs, to: .trash)
                }
                .onKeyPress(phases: [.down, .repeat], action: handleListKey)
            }

            Divider()
            HStack(spacing: 6) {
                Text(store.lastAction ?? "Saved on this Mac")
                    .lineLimit(1)
                    .help(store.lastAction ?? "Saved on this Mac")
                Spacer(minLength: 4)
                if store.canUndoMove {
                    Button("Undo", action: store.undoLastMove).buttonStyle(.plain)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 29)
        }
        .defaultFocus($isListFocused, true)
        .navigationTitle(searchesAllMailboxes ? store.selectedAccount.map { "\(MailAccount.scopeLabel(for: $0)) Search" } ?? "Search Results" : mailboxTitle)
        .sheet(isPresented: $showsViewEditor) { SavedInboxViewEditor(store: store, editing: store.selectedSavedView) }
        .sheet(isPresented: $showsInboxManager) { InboxManagementView(store: store) }
        .sheet(isPresented: $showsProviderSearch) { ProviderSearchView(runtime: runtime) }
        .sheet(item: $scheduleTarget) { message in
            MailScheduleSheet(purpose: schedulePurpose) { date, onlyIfNoReply in
                if schedulePurpose == .snooze { store.snoozeMessage(message.id, until: date) }
                else { store.setFollowUp(message.id, at: date, onlyIfNoReply: onlyIfNoReply) }
            }
        }
        .sheet(item: $noteTarget) { message in PrivateNoteSheet(store: store, message: message) }
        .background {
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
    }

    private var searchControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                PostmereIcon("magnifyingglass", size: 12)
                    .foregroundStyle(PostmereTheme.icon)
                    .accessibilityHidden(true)
                TextField("Search messages", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search messages")
                    .help("Search \(searchLocation) · ⌘F")
                    .onExitCommand {
                        if store.searchText.isEmpty {
                            isSearchFocused = false
                            isListFocused = !store.filteredMessages.isEmpty
                        } else { store.searchText = "" }
                    }
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        PostmereIcon("xmark.circle.fill", size: 12).foregroundStyle(PostmereTheme.icon)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 29)
            .background(PostmereTheme.subtleFill, in: RoundedRectangle(cornerRadius: 6))

            if isSearchFocused || !query.isEmpty {
                HStack(spacing: 8) {
                    Picker("Search scope", selection: $store.searchScope) {
                        Text("This Mailbox").tag(MailSearchScope.currentMailbox)
                        Text("All Mailboxes").tag(MailSearchScope.allMailboxes)
                    }
                    .help(store.selectedAccount.map { "Search within your \(MailAccount.scopeLabel(for: $0)) account" } ?? "Search across all accounts")
                    Spacer(minLength: 0)
                    Picker("Search field", selection: $store.searchField) {
                        ForEach(MailSearchField.allCases) { field in
                            Text(field.title).tag(field)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .font(.system(size: 11))
                HStack {
                    Text("Searching mail saved on this Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if runtime.backend.isConnected {
                        Button("Search online…") { showsProviderSearch = true }.buttonStyle(.plain)
                            .font(.system(size: 10)).foregroundStyle(PostmereTheme.accentInk)
                    }
                    Button("Search tips") { showsSearchHelp = true }.buttonStyle(.plain)
                        .font(.system(size: 10)).foregroundStyle(PostmereTheme.accentInk)
                        .popover(isPresented: $showsSearchHelp) {
                            MailSearchHelp { store.searchText = $0 }
                        }
                }
                if !query.isEmpty { MailSearchTokenControls(store: store) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var filterControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(store.filteredMessages.count == 1 ? "1 message" : "\(store.filteredMessages.count) messages")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
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
                    PostmereLabel("Filter", symbol: hasMessageFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", size: 12)
                        .foregroundStyle(hasMessageFilters ? AnyShapeStyle(PostmereTheme.accentInk) : AnyShapeStyle(PostmereTheme.icon))
                }
                .menuStyle(.borderlessButton)
                .tint(hasMessageFilters ? PostmereTheme.accentInk : PostmereTheme.icon)
                .fixedSize()
                .font(.system(size: 11))
                .help(hasMessageFilters ? "Filtering: \(activeFilterNames)" : "Filter messages")
                .accessibilityLabel("Filter messages")
                .accessibilityValue(hasMessageFilters ? activeFilterNames : "No filters")
            }
            if hasMessageFilters {
                HStack(spacing: 8) {
                    Text(activeFilterNames)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Clear", action: clearMessageFilters)
                        .buttonStyle(.plain)
                        .foregroundStyle(PostmereTheme.accentInk)
                        .accessibilityLabel("Clear message filters")
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 12)
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
                    Button(hasMessageFilters ? "Clear Search and Filters" : "Clear Search") { store.clearFilters() }
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
        if !message.isDraft && message.mailbox != .trash {
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
            Menu { bulkActions } label: { PostmereIcon("ellipsis.circle", size: 14) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More actions for selected messages")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var bulkActions: some View {
        Button("Archive Selected") { store.moveMessages(store.selectedMessageIDs, to: .archive) }
        Button("Move Selected to Trash", role: .destructive) { store.moveMessages(store.selectedMessageIDs, to: .trash) }
        Divider()
        Button("Mark as Read") { store.setRead(true, for: store.selectedMessageIDs) }
        Button("Mark as Unread") { store.setRead(false, for: store.selectedMessageIDs) }
        Button("Star Selected") { store.setStarred(true, for: store.selectedMessageIDs) }
        Button("Remove Stars") { store.setStarred(false, for: store.selectedMessageIDs) }
        Divider()
        Button("Needs Reply") { store.setNeedsReply(true, for: store.selectedMessageIDs) }
        Button("Mark Done") { store.setNeedsReply(false, for: store.selectedMessageIDs) }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        guard isListFocused && !isSearchFocused,
              press.modifiers.isEmpty || (press.characters == "#" && press.modifiers == .shift) else { return .ignored }
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
    let conversationCount: Int
    var showsLocation = false
    var outgoingItem: OutgoingMailItem?
    var isSelected = false
    @AppStorage("showMessagePreviews") private var showMessagePreviews = true

    private var senderTitle: String {
        guard message.isOutgoing else { return message.sender }
        let recipients = message.toRecipients.joined(separator: ", ")
        return recipients.isEmpty ? "No recipient" : "To: \(recipients)"
    }

    private var secondaryForeground: HierarchicalShapeStyle { isSelected ? .primary : .secondary }
    private var indicatorForeground: AnyShapeStyle {
        isSelected ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(PostmereTheme.icon)
    }
    private var unreadFill: AnyShapeStyle {
        guard message.isUnread else { return AnyShapeStyle(Color.clear) }
        return isSelected ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(PostmereTheme.accentInk)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(unreadFill)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .accessibilityHidden(true)
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
                    Text(message.timeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryForeground)
                        .fixedSize()
                }
                HStack(spacing: 7) {
                    Text(message.displaySubject)
                        .font(.system(size: 12, weight: message.isUnread ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if message.isStarred || !message.attachments.isEmpty { messageIndicators }
                }
                if showMessagePreviews {
                    Text(message.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(secondaryForeground)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showsLocation {
                    Text("\(message.accountLabel) · \(message.mailbox.title)")
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
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red))
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
