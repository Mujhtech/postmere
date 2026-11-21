import SwiftUI

struct ContentView: View {
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Bindable var store: MailStore
    @Environment(\.openWindow) private var openWindow
    @Environment(MailRuntime.self) private var runtime
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var wideColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var isCompact = false
    @State private var showsMailboxes = false
    @State private var preSearchVisibility: NavigationSplitViewVisibility?
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    @State private var listFocusRequest = 0
    @State private var editingCompactSearch = false
    @State private var searchCancel = SearchFieldCancel()

    private var showsSearchButton: Bool {
        isCompact && store.hasMessageSelection && !editingCompactSearch
    }

    private var showsSidebar: Bool {
        !isCompact && !store.isSearchActive && columnVisibility == .all
    }

    private var minimumMailListWidth: CGFloat {
        if store.isSearchActive { return isCompact ? 260 : 380 }
        // Without the sidebar, this column also houses the window controls and mailbox switcher.
        return showsSidebar ? 260 : 338
    }

    private var mailColumns: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
                .frame(minWidth: 190)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if showsSidebar {
                        ToolbarItemGroup(placement: .automatic) {
                            sidebarToggle
                            composeButton
                        }
                    }
                }
        } content: {
            MailListView(store: store, listFocusRequest: listFocusRequest)
                .frame(minWidth: !showsSidebar && !store.isSearchActive ? minimumMailListWidth : nil)
                .navigationSplitViewColumnWidth(min: minimumMailListWidth,
                                                ideal: store.isSearchActive ? 385 : 340, max: 430)
        } detail: {
            Group {
                if MailAccount.allCases.isEmpty && store.selectedMessage == nil && !store.isSearchActive {
                    WorkspaceConnectionEmptyView()
                } else {
                    ReaderView(store: store, compactToolbar: isCompact)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            .background(theme == .native ? Color.clear : theme.colors(for: scheme).canvas)
            .toolbar {
                if !store.hasMessageSelection && !store.isSearchActive {
                    // Keep the toolbar divider aligned with the list when the reader has no actions.
                    ToolbarSpacer(.flexible, placement: .automatic)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var searchableMailbox: some View {
        mailColumns
            .background {
                if !showsSearchButton {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .searchable(text: Binding(get: { store.searchText }, set: store.updateSearchText),
                                    isPresented: $searchPresented, placement: .toolbar, prompt: "Search mail")
                        .searchFocused($searchFocused)
                        .onSubmit(of: .search, openSearchResult)
                }
            }
        .onChange(of: searchPresented) {
            if searchPresented { store.beginSearch() }
            else if store.isSearchActive && !showsSearchButton { store.endSearch() }
        }
        .onChange(of: editingCompactSearch ? store.selectedMessageID : nil) { _, selected in
            if selected != nil { editingCompactSearch = false }
        }
        .onChange(of: searchFocused) {
            if !searchFocused { editingCompactSearch = false }
        }
        .onChange(of: store.isSearchActive) {
            if store.isSearchActive {
                // The field's ✕ leaves search entirely, as in Mail, not just clears it.
                searchCancel.onCancel = { [store] in store.endSearch() }
                DispatchQueue.main.async { searchCancel.install(in: NSApp.keyWindow) }
                preSearchVisibility = isCompact ? wideColumnVisibility : columnVisibility
                columnVisibility = .doubleColumn
            } else {
                searchPresented = false
                searchFocused = false
                editingCompactSearch = false
                if let previous = preSearchVisibility {
                    wideColumnVisibility = previous
                    columnVisibility = isCompact ? .doubleColumn : previous
                }
                preSearchVisibility = nil
            }
        }
        .onChange(of: runtime.shouldFocusMailSearch, initial: true) {
            guard runtime.shouldFocusMailSearch else { return }
            runtime.shouldFocusMailSearch = false
            focusSearch()
        }
    }

    var body: some View {
        searchableMailbox
        .mailboxWindowSurface()
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width < 960
        } action: { compact in
            isCompact = compact
            if store.isSearchActive {
                showsMailboxes = false
                columnVisibility = .doubleColumn
            } else if compact {
                wideColumnVisibility = columnVisibility
                columnVisibility = .doubleColumn
            } else {
                showsMailboxes = false
                columnVisibility = wideColumnVisibility
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .focusedSceneValue(\.mailStore, store)
        .focusedSceneValue(\.isComposerWindow, false)
        .onAppear { runtime.openMailWindow = { openWindow(id: "mail") } }
        .overlay {
            // Triage takes over the window in place, not as a separate sheet.
            if let session = runtime.triage {
                TriageView(session: session, store: store) {
                    withAnimation(.spring(duration: 0.45, bounce: 0.1)) {
                        runtime.triage = nil
                        // Back to the home page, not the last conversation triaged.
                        store.showMailboxOverview()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.1), value: runtime.triage == nil)
        .overlay(alignment: .bottomTrailing) {
            MailStatusNotices(store: store, pendingMailLinks: runtime.mailLinks)
        }
        .onChange(of: runtime.mailLinks.canOpen(in: store, verifiedScope: runtime.backend.scope), initial: true) {
            if runtime.backend.canAccessWorkspace {
                runtime.mailLinks.openNext(in: store, verifiedScope: runtime.backend.scope)
            }
        }
        .sheet(isPresented: Binding(get: { runtime.showsCommandPalette }, set: { runtime.showsCommandPalette = $0 }), onDismiss: runtime.finishPaletteDismissal) {
            CommandPaletteView(store: store, runtime: runtime)
        }
        .sheet(isPresented: Binding(get: { runtime.showsAttachmentLibrary }, set: { runtime.showsAttachmentLibrary = $0 })) {
            AttachmentLibraryView(store: store, runtime: runtime)
        }
        .sheet(isPresented: Binding(get: { runtime.showsSavedViewEditor }, set: { runtime.showsSavedViewEditor = $0 })) {
            SavedInboxViewEditor(store: store)
        }
        .sheet(isPresented: Binding(get: { runtime.showsInboxManager }, set: { runtime.showsInboxManager = $0 })) {
            InboxManagementView(store: store)
        }
        .sheet(isPresented: Binding(get: { runtime.showsCalendar }, set: { runtime.showsCalendar = $0 })) {
            CalendarHomeView(runtime: runtime)
        }
        .sheet(isPresented: Binding(get: { runtime.showsWorkspace }, set: { runtime.showsWorkspace = $0 })) {
            WorkspaceView(runtime: runtime)
        }
        .onChange(of: store.isComposing) {
            if store.isComposing { openWindow(id: "compose") }
        }
        .toolbar {
            if showsSearchButton {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: focusSearch) {
                        PostmereLabel("Search", symbol: "magnifyingglass", size: 16).labelStyle(.iconOnly)
                    }
                    .help("Search mail · ⌘F")
                    .accessibilityLabel("Search mail")
                }
                .visibilityPriority(.high)
            }
            if !showsSidebar {
                ToolbarItem(placement: .navigation) {
                    sidebarToggle
                        .popover(isPresented: $showsMailboxes, arrowEdge: .bottom) {
                            SidebarView(store: store, onSelect: { showsMailboxes = false })
                                .safeAreaInset(edge: .top, alignment: .trailing, spacing: 0) {
                                    composeButton
                                        .labelStyle(.iconOnly)
                                        .padding(8)
                                }
                                .frame(width: 240, height: 480)
                        }
                }
            }
        }
    }

    private var sidebarToggle: some View {
        Button {
            if isCompact || store.isSearchActive {
                showsMailboxes.toggle()
            } else {
                columnVisibility = showsSidebar ? .doubleColumn : .all
            }
        } label: {
            PostmereLabel("Mailboxes", symbol: "sidebar.left", size: 16)
                .foregroundStyle(PostmereTheme.icon)
        }
        .help(showsSidebar ? "Hide sidebar" : "Show mailboxes")
        .accessibilityLabel("Mailboxes")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private var composeButton: some View {
        Button {
            showsMailboxes = false
            store.beginCompose()
            openWindow(id: "compose")
        } label: {
            PostmereLabel("New Message", symbol: "square.and.pencil", size: 16)
                .foregroundStyle(PostmereTheme.icon)
        }
        .help("New Message · ⌘N")
        .accessibilityLabel("New Message")
        .disabled(MailAccount.sendingAccounts.isEmpty)
    }

    private func openSearchResult() {
        guard store.isSearchActive, !store.isSearchingMessages,
              let result = store.selectedMessage ?? store.filteredMessages.first else { return }
        store.select(result)
        editingCompactSearch = false
        listFocusRequest += 1
    }

    private func focusSearch() {
        editingCompactSearch = isCompact
        store.beginSearch()
        searchPresented = true
        searchFocused = true
        DispatchQueue.main.async {
            if let item = NSApp.keyWindow?.toolbar?.items.first(where: { $0 is NSSearchToolbarItem }) as? NSSearchToolbarItem {
                item.beginSearchInteraction()
            }
        }
    }
}

#Preview {
    let runtime = MailRuntime(store: MailStore())
    ContentView(store: runtime.store).environment(runtime).frame(width: 1280, height: 820)
}

/// Routes the toolbar search field's ✕ to leaving search, as in Mail, rather
/// than only clearing the text.
@MainActor final class SearchFieldCancel: NSObject {
    var onCancel: () -> Void = {}
    private weak var field: NSSearchField?

    func install(in window: NSWindow?) {
        guard let item = window?.toolbar?.items.first(where: { $0 is NSSearchToolbarItem }) as? NSSearchToolbarItem,
              let cell = item.searchField.cell as? NSSearchFieldCell else { return }
        field = item.searchField
        cell.cancelButtonCell?.target = self
        cell.cancelButtonCell?.action = #selector(cancel(_:))
    }

    @objc private func cancel(_ sender: Any?) {
        field?.stringValue = ""
        if let window = field?.window,
           let item = window.toolbar?.items.first(where: { $0 is NSSearchToolbarItem }) as? NSSearchToolbarItem {
            item.endSearchInteraction()
        }
        onCancel()
    }
}

