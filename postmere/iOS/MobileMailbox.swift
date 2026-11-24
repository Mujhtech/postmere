import SwiftUI

/// A stack on iPhone and a split view on iPad, over the same mailbox screen.
struct MobileMailbox: View {
    @Bindable var runtime: MailRuntime
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [UUID] = []
    @State private var showsSettings = false
    @State private var presenter = MobilePresenter()
    @State private var tab: MobileTab = .home
    @State private var selecting = false
    @State private var switchesAccount = false
    @State private var barHeight: CGFloat = 0
    private var store: MailStore { runtime.store }
    private var compact: Bool { sizeClass == .compact }
    /// Hidden while reading (the reply bar is there) and while picking messages.
    private var showsTabBar: Bool { compact && !(tab == .home && (!path.isEmpty || selecting)) }
    /// Triage presents its own composer for replies while a pass is on screen.
    private var triageHostsComposer: Bool { runtime.triage != nil && (!compact || tab == .triage) }

    var body: some View {
        Group {
            if compact {
                ZStack {
                    NavigationStack(path: $path) {
                        MailboxScreen(runtime: runtime, showsSettings: $showsSettings, isSelecting: $selecting,
                                      onOpen: { path = [$0] })
                            .navigationDestination(for: UUID.self) { _ in MobileConversation(runtime: runtime) }
                    }
                    .onChange(of: path) { if path.isEmpty { store.selectedMessageID = nil } }
                    .tabLayer(tab == .home)
                    MobileAskScreen(runtime: runtime, embedded: true) { message in
                        store.selectAccount(message.account)
                        store.selectedInboxSplitID = nil
                        store.selectedMailbox = message.mailbox
                        store.select(message)
                        tab = .home
                        path = [message.id]
                    }
                    .tabLayer(tab == .ai)
                    MobileTriageTab(runtime: runtime, isActive: tab == .triage)
                        .tabLayer(tab == .triage)
                }
                .environment(\.mobileTabBarInset, showsTabBar ? barHeight : 0)
                .overlay(alignment: .bottom) {
                    if showsTabBar {
                        VStack(spacing: 12) {
                            if tab == .home && !MailAccount.allCases.isEmpty { MobileHomeAccessory(store: store) }
                            MobileTabBar(selection: $tab) { switchesAccount = true }
                        }
                        .padding(.top, 10)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { barHeight = $0 }
                        .background {
                            LinearGradient(stops: [.init(color: Mobile.background.opacity(0), location: 0),
                                                   .init(color: Mobile.background.opacity(0.96), location: 0.16),
                                                   .init(color: Mobile.background, location: 0.45)],
                                           startPoint: .top, endPoint: .bottom)
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.3), value: showsTabBar)
                .sheet(isPresented: $switchesAccount) { MobileAccountSwitcher(runtime: runtime) }
                #if DEBUG
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("-PostmereOpenAsk") { tab = .ai }
                    if arguments.contains("-PostmereOpenTriage") { tab = .triage }
                    if arguments.contains("-PostmereOpenAccounts") { switchesAccount = true }
                    if arguments.contains("-PostmereOpenCompose") { store.beginCompose() }
                    if arguments.contains("-PostmereOpenSettings") { showsSettings = true }
                }
                #endif
            } else {
                NavigationSplitView {
                    MailboxScreen(runtime: runtime, showsSettings: $showsSettings, isSelecting: $selecting, onOpen: { _ in })
                        .navigationSplitViewColumnWidth(min: 340, ideal: 380)
                } detail: {
                    NavigationStack { MobileConversation(runtime: runtime) }
                }
            }
        }
        .overlay(alignment: .bottom) { MobileActionToast(store: store).padding(.bottom, showsTabBar ? barHeight + 12 : 74) }
        .environment(presenter)
        .sheet(isPresented: $showsSettings) { MobileSettings(runtime: runtime) }
        .sheet(item: $presenter.task) { MobileTaskSheet(task: $0, runtime: runtime) }
        .fullScreenCover(isPresented: Binding(get: { runtime.triage != nil && !compact },
                                              set: { if !$0 { runtime.triage = nil } })) {
            if let session = runtime.triage {
                MobileTriageScreen(session: session, runtime: runtime)
                    .environment(presenter)
            }
        }
        // While triage is open it presents its own composer for replies.
        .fullScreenCover(isPresented: Binding(get: { store.isComposing && !triageHostsComposer }, set: { _ in })) {
            MobileComposer(runtime: runtime)
                .environment(presenter)
                .sheet(item: $presenter.task) { MobileTaskSheet(task: $0, runtime: runtime) }
        }
        .alert("Postmere", isPresented: Binding(get: { store.operationError != nil },
                                                set: { if !$0 { store.operationError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.operationError ?? "")
        }
        // Widgets show what's in the mailbox; refresh them shortly after it settles.
        .task(id: store.mailboxDataRevision) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            MobileWidgetSync.publish(runtime: runtime)
        }
        .onChange(of: MobileRouter.shared.pending, initial: true) { openPendingLink() }
        .onAppear {
            runtime.openMailWindow = { if let id = store.selectedMessageID { path = [id] } }
            if runtime.backend.canAccessWorkspace {
                runtime.mailLinks.openNext(in: store, verifiedScope: runtime.backend.scope)
            }
        }
    }
}

extension MobileMailbox {
    /// Opens a `postmere://` link from a widget or control.
    fileprivate func openPendingLink() {
        guard let route = MobileRouter.shared.pending else { return }
        MobileRouter.shared.pending = nil
        switch route {
        case .inbox, .needsReply:
            tab = .home
            path = []
            store.selectMailbox(route == .inbox ? .inbox : .needsReply)
        case .compose:
            if !store.isComposing { store.beginCompose() }
        case .ask:
            tab = .ai
        case .triage:
            tab = .triage
        case .message(let id):
            guard let message = store.messages.first(where: { $0.id == id }) else {
                tab = .home
                return
            }
            tab = .home
            store.selectMailbox(message.mailbox)
            store.select(message)
            path = [message.id]
        }
    }
}

// MARK: - Mailbox screen

private struct MailboxScreen: View {
    @Bindable var runtime: MailRuntime
    @Binding var showsSettings: Bool
    /// Reported up so the tab bar can step aside while picking messages.
    @Binding var isSelecting: Bool
    let onOpen: (UUID) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsMailboxes = false
    @State private var searchPresented = false
    @State private var asks = false
    @State private var searchesOnline = false
    @State private var savesView = false
    @State private var editingView: SavedInboxView?
    @State private var managesTabs = false
    #if DEBUG
    @State private var debugOpened = false
    #endif
    @State private var editMode: EditMode = .inactive
    @State private var picked: Set<UUID> = []
    @Environment(\.postmereAccent) private var palette
    @Environment(MobilePresenter.self) private var presenter
    private var selecting: Bool { editMode.isEditing }
    /// On iPhone, search, compose, Ask and Triage live in the tab bar.
    private var usesTabBar: Bool { sizeClass == .compact }
    private var store: MailStore { runtime.store }
    private var hasAccounts: Bool { !MailAccount.allCases.isEmpty }

    /// One row per conversation, as in Mail: the newest message stands for the thread,
    /// and opening it shows all of them. Search results stay one row per message.
    private var conversations: ConversationRows? {
        if store.isSearchActive { return ConversationRows(ungrouped: store.searchResults) }
        return store.mailboxViewData.map { ConversationRows(Array($0.messages)) }
    }

    private var rows: [MailMessage]? { conversations?.rows }

    /// Every message a row stands for, so swipes and batch actions take the whole thread.
    private func members(_ ids: Set<UUID>) -> Set<UUID> {
        guard let conversations else { return ids }
        return Set(ids.flatMap { conversations.members[$0] ?? [$0] })
    }

    var body: some View {
        Group {
            if !hasAccounts {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MailboxHeader(runtime: runtime, rows: nil, showsSettings: $showsSettings,
                                      showsMailboxes: $showsMailboxes, showsSplits: false,
                                      selection: nil, onSelect: {}, onSelectAll: {}, onAsk: nil, onTriage: nil)
                        MobileConnectAccounts(runtime: runtime).padding(.top, 80)
                    }
                }
            } else {
                list
            }
        }
        .background(Mobile.background)
        .aboveMobileTabBar()
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationTitle(store.isSearchActive ? "Search" : store.selectedMailbox.title)
        .toolbar {
            if selecting {
                batchToolbar
            } else if hasAccounts && !usesTabBar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Compose", systemImage: "square.and.pencil") { store.beginCompose() }
                        .buttonStyle(.glassProminent)
                        .tint(palette.accent)
                        .disabled(MailAccount.sendingAccounts.isEmpty)
                }
            }
        }
        .modifier(MailSearch(store: store, isPresented: $searchPresented, enabled: hasAccounts && !usesTabBar))
        .onChange(of: editMode.isEditing) { isSelecting = editMode.isEditing }
        .task(id: store.isSearchActive ? nil : store.mailboxViewKey) { await store.loadMailboxView() }
        #if DEBUG
        .task(id: rows?.first?.id) {
            if ProcessInfo.processInfo.arguments.contains("-PostmereOpenFirst"), let first = rows?.first,
               !debugOpened {
                debugOpened = true
                open(first)
            }
        }
        #endif
        .sheet(isPresented: $showsMailboxes) {
            MobileMailboxSheet(store: store, runtime: runtime) { message in openFound(message) }
        }
        .sheet(isPresented: $searchesOnline) {
            MobileOnlineSearchSheet(runtime: runtime, initialQuery: store.searchText) { message in openFound(message) }
        }
        .sheet(isPresented: $savesView) { MobileSaveViewSheet(store: store) }
        .sheet(item: $editingView) { MobileSaveViewSheet(store: store, editing: $0) }
        .sheet(isPresented: $managesTabs) {
            NavigationStack {
                MobileInboxTabsSettings(store: store)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done", systemImage: "checkmark") { managesTabs = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $asks) {
            MobileAskScreen(runtime: runtime) { message in
                store.selectAccount(message.account)
                store.selectedInboxSplitID = nil
                store.selectedMailbox = message.mailbox
                open(message)
            }
        }
    }

    private var list: some View {
        List(selection: $picked) {
            MailboxHeader(runtime: runtime, rows: rows, showsSettings: $showsSettings,
                          showsMailboxes: $showsMailboxes, showsSplits: !store.isSearchActive && !selecting,
                          selection: selecting ? picked.count : nil,
                          onSelect: { toggleSelecting(rows: rows) },
                          onSelectAll: { picked = Set(rows?.map(\.id) ?? []) },
                          onAsk: runtime.backend.canAccessWorkspace && !usesTabBar ? { asks = true } : nil,
                          onTriage: (rows?.isEmpty ?? true) || store.isSearchActive || usesTabBar ? nil
                              : { runtime.startTriage(rows ?? [], store: store) },
                          onSaveView: { savesView = true },
                          onSearchOnline: runtime.backend.accounts.isEmpty ? nil : { searchesOnline = true },
                          onEditView: { editingView = $0 },
                          onManageTabs: { managesTabs = true })
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            if let rows {
                if rows.isEmpty {
                    emptyMailbox
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 90)
                } else {
                    messages(rows)
                }
                if store.isSearchActive && !runtime.backend.accounts.isEmpty
                    && !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchOnlineRow
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .environment(\.editMode, $editMode)
        .refreshable { await runtime.sync() }
        .onChange(of: store.mailboxViewKey) { endSelecting() }
    }

    private var searchOnlineRow: some View {
        Button { searchesOnline = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 38, height: 38)
                    .background(palette.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Search online for “\(store.searchText.trimmingCharacters(in: .whitespaces))”")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Finds older mail that isn’t on this iPhone").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: Mobile.gutter, bottom: 14, trailing: Mobile.gutter))
    }

    private func toggleSelecting(rows: [MailMessage]?) {
        withAnimation(.snappy) {
            if selecting { endSelecting() } else { editMode = .active }
        }
    }

    private func endSelecting() {
        editMode = .inactive
        picked = []
    }

    /// Batch actions for the picked messages, in place of search and compose.
    @ToolbarContentBuilder private var batchToolbar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("Archive", systemImage: "archivebox") { batch { store.moveMessages($0, to: .archive) } }
                .disabled(picked.isEmpty)
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Trash", systemImage: "trash") { batch { store.moveMessages($0, to: .trash) } }
                .disabled(picked.isEmpty)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Menu("More", systemImage: "ellipsis") {
                Section {
                    Button("Mark as Read", systemImage: "envelope.open") { batch { store.setRead(true, for: $0) } }
                    Button("Mark as Unread", systemImage: "envelope.badge") { batch { store.setRead(false, for: $0) } }
                    Button("Star", systemImage: "star") { batch { store.setStarred(true, for: $0) } }
                    Button("Remove Star", systemImage: "star.slash") { batch { store.setStarred(false, for: $0) } }
                }
                Section {
                    Button("Needs Reply", systemImage: "arrowshape.turn.up.left.circle") { batch { store.setNeedsReply(true, for: $0) } }
                    Button("Mark Done", systemImage: "checkmark.circle") { batch { store.setNeedsReply(false, for: $0) } }
                    Button("Snooze…", systemImage: "moon.zzz") {
                        let ids = members(picked)
                        endSelecting()
                        presenter.task = .snooze(ids)
                    }
                }
                Section {
                    Button("Move to Junk", systemImage: "xmark.bin") { batch { store.moveMessages($0, to: .junk) } }
                }
            }
            .disabled(picked.isEmpty)
        }
    }

    private func batch(_ work: (Set<UUID>) -> Void) {
        let ids = members(picked)
        guard !ids.isEmpty else { return }
        work(ids)
        withAnimation(.snappy) { endSelecting() }
    }

    @ViewBuilder private var emptyMailbox: some View {
        if store.isSearchActive {
            VStack(spacing: 14) {
                MobileEmptyState(symbol: "magnifyingglass", title: "No matches",
                                 message: "Try a name, an address or fewer words.")
                if store.searchScope == .currentMailbox {
                    Button("Search All Mailboxes") { store.searchScope = .allMailboxes }
                        .buttonStyle(.glass)
                }
            }
        } else if store.unreadOnly || store.attachmentsOnly {
            VStack(spacing: 14) {
                MobileEmptyState(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                                 message: "No messages here fit the filters you chose.")
                Button("Show All Messages") {
                    store.unreadOnly = false
                    store.attachmentsOnly = false
                }
                .buttonStyle(.glass)
            }
        } else if store.selectedMailbox == .inbox {
            MobileEmptyState(symbol: "checkmark.circle", title: "Inbox zero",
                             message: "You’re all caught up. Pull down to check for new mail.")
        } else {
            MobileEmptyState(symbol: store.selectedMailbox.mobileSymbol, title: "Nothing here",
                             message: "Messages in \(store.selectedMailbox.title) will appear here.")
        }
    }

    private func messages(_ rows: [MailMessage]) -> some View {
        let counts = store.conversationCounts(for: rows)
        return ForEach(rows) { message in
            MobileMessageRow(message: message, conversationCount: counts[message.id] ?? 1,
                             showsMailbox: store.isSearchActive)
                .contentShape(Rectangle())
                .onTapGesture { if !selecting { open(message) } }
                .tag(message.id)
            .listRowBackground(store.selectedMessageID == message.id ? Mobile.raised : Mobile.background)
            .listRowInsets(EdgeInsets(top: 12, leading: Mobile.gutter, bottom: 12, trailing: Mobile.gutter))
            .alignmentGuide(.listRowSeparatorLeading) { _ in Mobile.gutter + 50 }
            .listRowSeparatorTint(Mobile.hairline)
            .swipeActions(edge: .leading) { leadingActions(message) }
            .swipeActions(edge: .trailing) { trailingActions(message) }
            .contextMenu {
                MobileMessageMenu(message: message, store: store)
            } preview: {
                MobileMessagePreviewCard(message: message)
            }
        }
    }

    /// Opens a message found outside the current list: in Files or an online search.
    private func openFound(_ message: MailMessage) {
        store.endSearch()
        store.selectAccount(message.account)
        store.selectedInboxSplitID = nil
        store.selectedMailbox = message.mailbox
        open(message)
    }

    private func open(_ message: MailMessage) {
        if message.isDraft {
            store.beginEditingDraft(message)
            return
        }
        store.select(message)
        onOpen(message.id)
    }

    @ViewBuilder private func leadingActions(_ message: MailMessage) -> some View {
        Button {
            // An unread thread is read once all of it is; marking unread flags just the newest.
            if message.isUnread { store.setRead(true, for: members([message.id])) }
            else { store.setRead(false, for: [message.id]) }
        } label: {
            Label(message.isUnread ? "Read" : "Unread",
                  systemImage: message.isUnread ? "envelope.open.fill" : "envelope.badge.fill")
        }
        .tint(.blue)
        if message.allowsWorkflowActions && message.mailbox != .trash && message.workflow.snoozedUntil == nil {
            Button { presenter.task = .snooze(members([message.id])) } label: {
                Label("Snooze", systemImage: "moon.zzz.fill")
            }
            .tint(.indigo)
        }
    }

    @ViewBuilder private func trailingActions(_ message: MailMessage) -> some View {
        if store.canMoveMessage(message, to: .archive) {
            Button { store.moveMessages(members([message.id]), to: .archive) } label: {
                Label("Done", systemImage: "checkmark")
            }
            .tint(palette.accent)
        } else if store.canMoveMessage(message, to: .inbox) {
            Button { store.moveMessages(members([message.id]), to: .inbox) } label: {
                Label("Inbox", systemImage: "tray.and.arrow.down.fill")
            }
            .tint(palette.accent)
        }
        if store.canMoveMessage(message, to: .trash) {
            Button(role: .destructive) { store.moveMessages(members([message.id]), to: .trash) } label: {
                Label("Trash", systemImage: "trash.fill")
            }
        }
    }
}

/// Search lives in the bottom bar and only exists once there's mail to search.
private struct MailSearch: ViewModifier {
    let store: MailStore
    @Binding var isPresented: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: Binding(get: { store.searchText }, set: store.searchFieldChanged),
                            isPresented: $isPresented, prompt: "Search")
                .onChange(of: isPresented) {
                    if !isPresented, store.isSearchActive { store.endSearch() }
                }
        } else {
            content
        }
    }
}

// MARK: - Header

/// The mailbox name (a menu to every other mailbox), the account photo, one status line,
/// and split-inbox chips that jump between the views worth checking on a phone.
private struct MailboxHeader: View {
    let runtime: MailRuntime
    let rows: [MailMessage]?
    @Binding var showsSettings: Bool
    @Binding var showsMailboxes: Bool
    let showsSplits: Bool
    /// The number picked while selecting, else nil.
    let selection: Int?
    let onSelect: () -> Void
    let onSelectAll: () -> Void
    let onAsk: (() -> Void)?
    let onTriage: (() -> Void)?
    var onSaveView: () -> Void = {}
    var onSearchOnline: (() -> Void)?
    var onEditView: (SavedInboxView) -> Void = { _ in }
    var onManageTabs: () -> Void = {}
    @AppStorage("showContactPhotos") private var showsPhotos = true
    @AppStorage("showMessagePreviews") private var showsPreviews = true
    @Environment(\.postmereAccent) private var palette
    @State private var counts: InboxTabCounts?
    private var store: MailStore { runtime.store }

    /// Filters and how the list looks, like the Mac's View menu.
    private var viewMenu: some View {
        @Bindable var store = store
        let filtered = store.unreadOnly || store.attachmentsOnly
        return Menu {
            Section("Show only") {
                Toggle(isOn: $store.unreadOnly) { Label("Unread", systemImage: "envelope.badge") }
                Toggle(isOn: $store.attachmentsOnly) { Label("With Attachments", systemImage: "paperclip") }
                if filtered {
                    Button("Show All Messages", systemImage: "xmark.circle") {
                        store.unreadOnly = false
                        store.attachmentsOnly = false
                    }
                }
            }
            Section("List") {
                Toggle(isOn: $showsPhotos) { Label("Sender Photos", systemImage: "person.crop.circle") }
                Toggle(isOn: $showsPreviews) { Label("Message Previews", systemImage: "text.alignleft") }
            }
            Section {
                if let view = store.selectedSavedView {
                    Button("Edit View…", systemImage: "pencil") { onEditView(view) }
                    Button("Delete View", systemImage: "trash", role: .destructive) { store.deleteSavedView(view.id) }
                } else {
                    Button("Save as View…", systemImage: "plus.rectangle.on.rectangle", action: onSaveView)
                }
                Button("Inbox Tabs & VIPs…", systemImage: "rectangle.split.3x1") { onManageTabs() }
            }
        } label: {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(filtered ? palette.accent : .primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(filtered ? "Filters, on" : "Filters and view options")
    }

    /// Mailboxes worth one tap on a phone, after the inbox tabs.
    private let quick: [Mailbox] = [.needsReply, .starred, .followUps, .newSenders]

    private var headerTitle: String {
        if let id = store.selectedSavedViewID, let view = store.savedViews.first(where: { $0.id == id }) { return view.name }
        return store.selectedMailbox.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if let selection {
                    Text(selection == 0 ? "Select" : "\(selection) selected")
                        .font(Mobile.screenTitle)
                        .contentTransition(.numericText(value: Double(selection)))
                        .accessibilityAddTraits(.isHeader)
                } else if store.isSearchActive {
                    Text("Search").font(Mobile.screenTitle).accessibilityAddTraits(.isHeader)
                } else {
                    Button { showsMailboxes = true } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(headerTitle).font(Mobile.screenTitle).lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint("Shows mailboxes and accounts")
                }
                Spacer(minLength: 8)
                if selection != nil {
                    Button("All", action: onSelectAll).buttonStyle(.glass)
                } else {
                    if let onTriage {
                        Button("Triage", systemImage: "rectangle.stack", action: onTriage)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .tint(.primary)
                    }
                    if let onAsk {
                        Button("Ask your mail", systemImage: "sparkles", action: onAsk)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .tint(.primary)
                    }
                }
                if selection == nil && !store.isSearchActive {
                    viewMenu
                }
                if selection != nil || rows?.isEmpty == false {
                    Button(selection == nil ? "Select" : "Done", action: onSelect)
                        .buttonStyle(.glass)
                        .tint(.primary)
                        .fontWeight(selection == nil ? .regular : .semibold)
                }
                Button { showsSettings = true } label: {
                    ParticipantPhoto(address: runtime.backend.accounts.first?.email ?? "",
                                     name: runtime.backend.accounts.first?.displayName ?? "", size: 34)
                        .overlay { Circle().strokeBorder(Mobile.hairline) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, Mobile.gutter)

            MobileMailboxStatus(runtime: runtime, rows: rows)
                .padding(.horizontal, Mobile.gutter)
                .padding(.top, -10)

            if showsSplits {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) { HStack(spacing: 8) {
                        let inInbox = store.selectedMailbox == .inbox && store.selectedSavedViewID == nil
                        SplitChip(title: store.visibleInboxSplits.isEmpty ? "Inbox" : "All",
                                  count: counts?.all ?? store.count(for: .inbox),
                                  selected: inInbox && store.selectedInboxSplitID == nil) {
                            withAnimation(.snappy(duration: 0.25)) { store.selectInboxSplit(nil) }
                        }
                        ForEach(store.visibleInboxSplits) { split in
                            SplitChip(title: split.name, count: counts?.splits[split.id] ?? 0,
                                      selected: inInbox && store.selectedInboxSplitID == split.id) {
                                withAnimation(.snappy(duration: 0.25)) { store.selectInboxSplit(split.id) }
                            }
                        }
                        Rectangle().fill(Mobile.hairline).frame(width: 1, height: 20).padding(.horizontal, 2)
                        ForEach(quick) { mailbox in
                            SplitChip(title: mailbox.splitTitle,
                                      count: mailbox == .needsReply ? store.count(for: mailbox) : 0,
                                      selected: store.selectedMailbox == mailbox && store.selectedSavedViewID == nil) {
                                withAnimation(.snappy(duration: 0.25)) { store.selectMailbox(mailbox) }
                            }
                        }
                    } }
                    .padding(.horizontal, Mobile.gutter)
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
                .task(id: store.inboxTabCountKey) {
                    let loaded = await store.loadInboxTabCounts()
                    if !Task.isCancelled { counts = loaded }
                }
                .task(id: store.inboxTabCountKey, priority: .utility) { await store.prepareInboxTabs() }
            } else if store.isSearchActive {
                MobileSearchFilters(store: store, onSaveView: onSaveView, onSearchOnline: onSearchOnline)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// Inverted when selected, the way a split inbox tab reads at a glance.
private struct SplitChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if count > 0 {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .opacity(selected ? 0.8 : 0.5)
                        .contentTransition(.numericText())
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(palette.accent).interactive() : .regular.interactive(), in: Capsule())
        .animation(.snappy(duration: 0.25), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One quiet line under the title: what's waiting, or what sync is doing.
private struct MobileMailboxStatus: View {
    let runtime: MailRuntime
    let rows: [MailMessage]?
    private var store: MailStore { runtime.store }

    var body: some View {
        HStack(spacing: 6) {
            if runtime.mailSyncActivity.isActive {
                ProgressView().controlSize(.mini)
                Text(runtime.mailSyncActivity.title + "…")
            } else if runtime.lastMailSyncError != nil {
                Image(systemName: "exclamationmark.circle")
                Text("Couldn’t sync. Pull to try again.")
            } else if store.isSearchActive || store.selectedMailbox != .inbox || MailAccount.allCases.count > 1 {
                Text(summary)
            }
        }
        .font(Mobile.meta)
        .foregroundStyle(runtime.lastMailSyncError != nil && !runtime.mailSyncActivity.isActive
                         ? AnyShapeStyle(PostmereTheme.destructiveInk) : AnyShapeStyle(.secondary))
        .lineLimit(1)
    }

    private var summary: String {
        let store = runtime.store
        let scope = MailAccount.scopeLabel(for: store.selectedAccount)
        if store.isSearchActive {
            let count = rows?.count ?? 0
            return count == 1 ? "1 result" : "\(count) results"
        }
        return scope
    }
}

// MARK: - Rows

/// Two lines: who and when, then the subject running into the preview.
struct MobileMessageRow: View {
    let message: MailMessage
    let conversationCount: Int
    let showsMailbox: Bool
    @Environment(\.postmereAccent) private var palette
    @AppStorage("showContactPhotos") private var showsPhotos = true
    @AppStorage("showMessagePreviews") private var showsPreviews = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if showsPhotos {
                    ParticipantPhoto(address: message.isOutgoing ? (message.toRecipients.first ?? "") : message.senderEmail,
                                     name: message.isOutgoing ? "" : message.sender, size: 38,
                                     verifiedMark: message.verifiedSenderMark)
                } else {
                    Color.clear.frame(width: 1, height: 20)
                }
            }
                .overlay(alignment: .leading) {
                    if message.isUnread {
                        Circle().fill(palette.accent).frame(width: 7, height: 7).offset(x: -12)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.isOutgoing ? recipients : message.sender)
                        .font(message.isUnread ? Mobile.rowSender : Mobile.rowSenderRead)
                        .foregroundStyle(message.isUnread ? .primary : .secondary)
                        .lineLimit(1)
                    if conversationCount > 1 {
                        Text(conversationCount, format: .number)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Mobile.raised, in: Capsule())
                    }
                    Spacer(minLength: 8)
                    MobileRowBadges(message: message)
                    if message.isStarred {
                        Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    if !message.attachments.isEmpty {
                        Image(systemName: "paperclip").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    Text(message.sentAt.mobileListDate)
                        .font(Mobile.meta)
                        .foregroundStyle(message.isUnread ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .monospacedDigit()
                }
                Text(subject)
                    .font(Mobile.rowLine.weight(message.isUnread ? .medium : .regular))
                    .foregroundStyle(message.isUnread ? .primary : .secondary)
                    .lineLimit(1)
                if showsPreviews {
                    Text(message.preview.isEmpty ? " " : message.preview)
                        .font(Mobile.rowLine)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if showsMailbox {
                    Label(message.mailbox.title, systemImage: message.mailbox.mobileSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(message.isUnread ? "Unread" : "")
        .accessibilityAddTraits(.isButton)
    }

    private var subject: String { message.subject.isEmpty ? "No subject" : message.subject }

    private var recipients: String {
        let names = message.toRecipients.map { $0.split(separator: "<").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? $0 }
        return names.isEmpty ? "No recipients" : "To " + names.joined(separator: ", ")
    }
}

extension Mailbox {
    var mobileSymbol: String {
        switch self {
        case .inbox: "tray"
        case .starred: "star"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .needsReply: "arrowshape.turn.up.left"
        case .snoozed: "moon.zzz"
        case .followUps: "bell"
        case .newSenders: "person.badge.plus"
        case .outbox: "tray.and.arrow.up"
        }
    }

    /// Short names for the split-inbox chips.
    var splitTitle: String {
        switch self {
        case .inbox: "Inbox"
        case .needsReply: "Needs reply"
        case .newSenders: "New senders"
        case .starred: "Starred"
        case .followUps: "Follow up"
        default: title
        }
    }
}

extension Date {
    /// Time today, weekday this week, otherwise a short date.
    var mobileListDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Mailbox picker

private struct MobileMailboxSheet: View {
    @Bindable var store: MailStore
    let runtime: MailRuntime
    var onOpen: (MailMessage) -> Void
    @State private var editing: SavedInboxView?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette

    private let groups: [[Mailbox]] = [[.inbox, .needsReply, .starred, .snoozed, .followUps, .newSenders],
                                       [.drafts, .sent, .outbox], [.archive, .junk, .trash]]

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups.indices, id: \.self) { index in
                    Section {
                        ForEach(groups[index].filter { $0 != .outbox || !store.outgoingQueue.isEmpty }) { row($0) }
                    }
                }
                Section("Library") {
                    NavigationLink {
                        MobileFilesScreen(runtime: runtime) { message in
                            dismiss()
                            onOpen(message)
                        }
                    } label: {
                        Label { Text("Files") } icon: { Image(systemName: "paperclip").foregroundStyle(.secondary) }
                    }
                    if runtime.backend.canAccessWorkspace {
                        NavigationLink { MobileSharedThreadsScreen(runtime: runtime) } label: {
                            Label { Text("Shared with Team") } icon: {
                                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !store.savedViews.isEmpty {
                    Section("Views") {
                        ForEach(store.savedViews) { view in
                            Button {
                                store.selectSavedView(view)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                        .foregroundStyle(store.selectedSavedViewID == view.id ? palette.accent : .secondary)
                                        .frame(width: 24)
                                    Text(view.name).foregroundStyle(.primary)
                                        .fontWeight(store.selectedSavedViewID == view.id ? .semibold : .regular)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSavedView(view.id) }
                                Button("Edit", systemImage: "pencil") { editing = view }.tint(.blue)
                            }
                        }
                    }
                }
                if MailAccount.allCases.count > 1 {
                    Section("Accounts") {
                        accountRow(nil, title: "All accounts", detail: nil)
                        ForEach(MailAccount.allCases) { account in
                            accountRow(account.rawValue, title: account.title,
                                       detail: account.title == account.email ? nil : account.email)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(14)
            .navigationTitle("Mailboxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $editing) { MobileSaveViewSheet(store: store, editing: $0) }
    }

    private func row(_ mailbox: Mailbox) -> some View {
        let selected = store.selectedMailbox == mailbox && store.selectedSavedViewID == nil
        let count = [.inbox, .needsReply, .drafts, .outbox].contains(mailbox) ? store.count(for: mailbox) : 0
        return Button {
            store.selectMailbox(mailbox)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: mailbox.mobileSymbol)
                    .foregroundStyle(selected ? palette.accent : .secondary)
                    .frame(width: 24)
                Text(mailbox.title).foregroundStyle(.primary)
                    .fontWeight(selected ? .semibold : .regular)
                Spacer()
                if count > 0 { Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func accountRow(_ id: String?, title: String, detail: String?) -> some View {
        Button {
            store.selectAccount(id)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let brand = MailAccount(rawValue: id ?? "")?.remote.flatMap({ Brand(mailProvider: $0.provider) }) {
                        BrandMark(brand: brand, size: 20)
                    } else {
                        Image(systemName: id == nil ? "tray.2" : "person.crop.circle").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if store.selectedAccount == id {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toast

/// The last move, with Undo while it still applies.
private struct MobileActionToast: View {
    let store: MailStore
    @State private var visible = false

    /// A just-queued send, still inside its undo window.
    private var sending: Bool { store.canUndoSend && store.lastAction?.hasPrefix("Uploading") == true }

    var body: some View {
        Group {
            if visible, let action = store.lastAction {
                HStack(spacing: 16) {
                    Text(sending ? "Sending…" : action).font(.subheadline.weight(.medium)).lineLimit(1)
                    if sending {
                        Button("Undo") {
                            store.undoLastSend()
                            visible = false
                        }
                        .font(.subheadline.weight(.bold))
                    } else if store.lastActionOffersUndo {
                        Button("Undo") {
                            store.undoLastMove()
                            visible = false
                        }
                        .font(.subheadline.weight(.bold))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: visible)
        .task(id: store.actionRevision) {
            guard store.lastAction != nil else { return }
            visible = true
            let undoWindow = store.latestUndoableSend.map { $0.undoUntil.timeIntervalSinceNow } ?? 0
            try? await Task.sleep(for: .seconds(max(4, undoWindow)))
            visible = false
        }
    }
}

// MARK: - Connecting accounts

/// A workspace without mail accounts. Gmail and Outlook connect in the browser.
struct MobileConnectAccounts: View {
    let runtime: MailRuntime
    @State private var connection = MailAccountConnection()

    var body: some View {
        VStack(spacing: 28) {
            MobileEmptyState(symbol: "tray.and.arrow.down", title: "Connect your mail",
                             message: "Add an inbox here or on your Mac. It shows up on every device in this workspace.")
            VStack(spacing: 12) {
                MobileProviderButtons(runtime: runtime, connection: connection)
                if let error = connection.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(PostmereTheme.destructiveInk)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
    }
}

/// "Continue with Gmail / Outlook", with the browser hand-off state.
struct MobileProviderButtons: View {
    let runtime: MailRuntime
    let connection: MailAccountConnection
    var calendarAccess = false

    private let providers: [(String, String, Brand)] = [("gmail", "Gmail", .gmail), ("microsoft", "Outlook", .outlook)]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(providers, id: \.0) { provider, name, logo in
                let waiting = connection.provider == provider
                Button {
                    connection.start(provider, session: runtime.backend, calendarAccess: calendarAccess) { await runtime.sync() }
                } label: {
                    HStack(spacing: 14) {
                        BrandMark(brand: logo, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(waiting ? "Finish in your browser…" : "Continue with \(name)")
                                .font(.body.weight(.semibold))
                            if waiting {
                                Text("Return here when you’ve signed in.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if waiting { ProgressView() } else { Image(systemName: "arrow.right").foregroundStyle(.tertiary) }
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 56)
                    .background(Mobile.raised, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(connection.provider != nil && !waiting)
                .opacity(connection.provider != nil && !waiting ? 0.5 : 1)
            }
            if connection.provider != nil {
                Button("Cancel") { connection.cancel() }
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
            }
        }
    }
}

/// Small workflow markers beside the date: needs reply, snoozed, follow-up, private note, sending.
private struct MobileRowBadges: View {
    let message: MailMessage

    var body: some View {
        HStack(spacing: 5) {
            if message.mailbox == .outbox {
                Image(systemName: "clock.fill").foregroundStyle(.secondary)
            }
            if message.needsReply {
                Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(.orange)
            }
            if message.workflow.snoozedUntil != nil {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
            }
            if message.workflow.followUpAt != nil {
                Image(systemName: "bell.fill").foregroundStyle(.secondary)
            }
            if !message.workflow.privateNote.isEmpty {
                Image(systemName: "note.text").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .accessibilityHidden(true)
    }
}

private extension View {
    /// Keeps a tab's screen alive while another is shown.
    func tabLayer(_ active: Bool) -> some View {
        opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

/// What a long-press on a row shows above its menu, as in Mail: who, to whom, when,
/// the subject and the start of the message, without opening or marking it read.
struct MobileMessagePreviewCard: View {
    let message: MailMessage
    @Environment(\.postmereAccent) private var palette
    @AppStorage("readingFontSize") private var fontSize = 14.0
    @AppStorage(MailReadingFont.preference) private var readingFont = MailReadingFont.original

    private var bodyText: String {
        let paragraphs = message.paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return paragraphs.isEmpty ? message.preview : paragraphs.prefix(12).joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if message.needsReply || message.isStarred {
                HStack(spacing: 6) {
                    if message.needsReply { tag("Needs reply", symbol: "arrowshape.turn.up.left.circle.fill") }
                    if message.isStarred { tag("Starred", symbol: "star.fill") }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ParticipantPhoto(address: message.isOutgoing ? (message.toRecipients.first ?? "") : message.senderEmail,
                                 name: message.isOutgoing ? "" : message.sender, size: 46,
                                 verifiedMark: message.verifiedSenderMark)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message.sender.isEmpty ? message.senderEmail : message.sender)
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(message.sentAt.mobileListDate)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !message.toRecipients.isEmpty {
                        recipients("To", message.toRecipients)
                    }
                    if !message.ccRecipients.isEmpty {
                        recipients("Cc", message.ccRecipients)
                    }
                }
            }
            Rectangle().fill(Mobile.hairline).frame(height: 0.5)
            Text(message.subject.isEmpty ? "No subject" : message.displaySubject)
                .font(.system(size: 22, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            // The same rendering as the reader: formatted HTML, rich text, or plain paragraphs.
            if let html = message.receivedHTML {
                HTMLMessageBody(html: html, paragraphs: message.paragraphs, fontSize: fontSize + 2, readingFont: readingFont)
                    .padding(.horizontal, -12)
                    .allowsHitTesting(false)
            } else if message.bodyRTF != nil || !message.paragraphs.isEmpty {
                RichTextMessageBody(rtf: message.bodyRTF, paragraphs: message.paragraphs,
                                    fontSize: fontSize + 2, readingFont: readingFont)
            } else {
                Text(verbatim: bodyText)
                    .font(.system(size: 16))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.attachments.isEmpty {
                Label(message.attachments.count == 1 ? message.attachments[0].name : "\(message.attachments.count) attachments",
                      systemImage: "paperclip")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .topLeading)
        .frame(maxHeight: 560, alignment: .top)
        .clipped()
        .background(Mobile.background)
    }

    private func recipients(_ label: String, _ values: [String]) -> some View {
        (Text("\(label): ").foregroundStyle(.primary) + Text(values.joined(separator: ", ")).foregroundStyle(.secondary))
            .font(.subheadline)
            .lineLimit(1)
    }

    private func tag(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.accent.opacity(0.12), in: Capsule())
    }
}

/// A mailbox list folded into conversations: the newest message of each thread,
/// shown unread or starred if any message in it is, and the IDs each row stands for.
struct ConversationRows {
    let rows: [MailMessage]
    let members: [UUID: Set<UUID>]

    init(_ messages: [MailMessage]) {
        var groups: [String: [MailMessage]] = [:]
        for message in messages { groups[message.searchConversationKey, default: []].append(message) }
        var members: [UUID: Set<UUID>] = [:]
        rows = MailSearchRequest.representatives(messages, preferred: nil).map { lead in
            let thread = groups[lead.searchConversationKey] ?? [lead]
            members[lead.id] = Set(thread.map(\.id))
            guard thread.count > 1 else { return lead }
            var shown = lead
            shown.isUnread = thread.contains(where: \.isUnread)
            shown.isStarred = thread.contains(where: \.isStarred)
            return shown
        }
        self.members = members
    }

    init(ungrouped messages: [MailMessage]) {
        rows = messages
        members = [:]
    }
}
