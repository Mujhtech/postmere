import SwiftUI

struct ContentView: View {
    @Bindable var store: MailStore
    @Environment(\.openWindow) private var openWindow
    @Environment(MailRuntime.self) private var runtime
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var wideColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var isCompact = false
    @State private var showsMailboxes = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
                .toolbar(removing: .sidebarToggle)
        } content: {
            MailListView(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 430)
        } detail: {
            Group {
                if MailAccount.allCases.isEmpty && store.selectedMessage == nil {
                    WorkspaceConnectionEmptyView()
                } else {
                    ReaderView(store: store)
                }
            }.frame(minWidth: 300)
        }
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width < 960
        } action: { compact in
            isCompact = compact
            if compact {
                wideColumnVisibility = columnVisibility
                columnVisibility = .doubleColumn
            } else {
                showsMailboxes = false
                columnVisibility = wideColumnVisibility
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .tint(PostmereTheme.accent)
        .focusedSceneValue(\.mailStore, store)
        .focusedSceneValue(\.isComposerWindow, false)
        .onAppear { runtime.openMailWindow = { openWindow(id: "mail") } }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBanners }
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
        .sheet(isPresented: Binding(get: { runtime.showsAIQuestion }, set: { runtime.showsAIQuestion = $0 })) {
            MailAIAssistantView(runtime: runtime, mode: .ask)
        }
        .sheet(isPresented: Binding(get: { runtime.showsWorkspace }, set: { runtime.showsWorkspace = $0 })) {
            WorkspaceView(runtime: runtime)
        }
        .sheet(item: Binding(get: { runtime.schedulePurpose }, set: { runtime.schedulePurpose = $0 })) { purpose in
            if let message = runtime.scheduleTarget {
                MailScheduleSheet(purpose: purpose) { date, conditional in
                    if purpose == .snooze { store.snoozeMessage(message.id, until: date) }
                    else { store.setFollowUp(message.id, at: date, onlyIfNoReply: conditional) }
                }
            }
        }
        .sheet(isPresented: Binding(get: { runtime.showsPrivateNote }, set: { runtime.showsPrivateNote = $0 })) {
            if let message = runtime.privateNoteTarget { PrivateNoteSheet(store: store, message: message) }
        }
        .onChange(of: store.isComposing) {
            if store.isComposing { openWindow(id: "compose") }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    if isCompact {
                        showsMailboxes.toggle()
                    } else {
                        columnVisibility = columnVisibility == .all ? .doubleColumn : .all
                    }
                } label: {
                    PostmereLabel("Mailboxes", symbol: "sidebar.left", size: 16)
                        .foregroundStyle(PostmereTheme.icon)
                }
                .help(isCompact ? "Show mailboxes" : "Show or hide sidebar")
                .accessibilityLabel("Mailboxes")
                .keyboardShortcut("s", modifiers: [.command, .control])
                .popover(isPresented: $showsMailboxes, arrowEdge: .bottom) {
                    SidebarView(store: store, onSelect: { showsMailboxes = false })
                        .frame(width: 240, height: 480)
                }

                Button {
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
        }
    }

    private var statusBanners: some View {
        VStack(spacing: 0) {
            if let error = store.persistenceError {
                banner(error, symbol: "externaldrive.badge.exclamationmark", isError: true) {
                    Button("Retry", action: store.retryPersistence)
                }
            }
            if let error = store.operationError {
                banner(error, symbol: "exclamationmark.circle", isError: true) {
                    Button("Dismiss") { store.operationError = nil }
                }
            }
            if store.draftRecoveryAvailable {
                banner("An unfinished message was recovered.", symbol: "doc") {
                    Button("Resume", action: store.recoverDraft)
                    Button("Discard", role: .destructive, action: store.discardRecoveredDraft)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let item = store.latestUndoableSend {
                    banner(item.scheduledAt > item.undoUntil
                           ? "Scheduled for \(item.scheduledAt.formatted(date: .abbreviated, time: .shortened))"
                           : "Message queued · sending in \(max(0, Int(ceil(item.undoUntil.timeIntervalSinceNow)))) seconds", symbol: "paperplane") {
                        Button("Undo Send", action: store.undoLastSend)
                    }
                }
            }
        }
    }

    private func banner<Actions: View>(_ text: String, symbol: String, isError: Bool = false, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            Label {
                Text(text).lineLimit(3)
            } icon: {
                PostmereIcon(symbol, size: 14).foregroundStyle(isError ? Color.red : PostmereTheme.icon)
            }
            Spacer()
            actions()
        }.font(.caption).controlSize(.small).padding(.horizontal, 18).padding(.vertical, 10)
            .background(.bar)
    }
}

#Preview {
    let runtime = MailRuntime(store: MailStore())
    ContentView(store: runtime.store).environment(runtime).frame(width: 1280, height: 820)
}
