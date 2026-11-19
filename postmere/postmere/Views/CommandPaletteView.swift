import SwiftUI

struct CommandPaletteView: View {
    @Bindable var store: MailStore
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private struct Action: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var shortcut = ""
        let run: () -> Void
    }

    private var actions: [Action] {
        var result: [Action] = []
        if !store.isComposing && !MailAccount.sendingAccounts.isEmpty {
            result.append(Action(id: "compose", title: "New message", symbol: "square.and.pencil", shortcut: "⌘N", run: { store.beginCompose() }))
        }
        if let message = store.selectedMessage {
            if !store.isComposing && (message.isDraft || !MailAccount.sendingAccounts.isEmpty) && message.mailbox != .outbox && store.selectedMessageIDs.count <= 1 {
                result.append(Action(id: "reply", title: message.isDraft ? "Edit draft" : "Reply", symbol: "arrowshape.turn.up.left", shortcut: "⌘R", run: {
                    if message.isDraft { store.beginEditingDraft(message) } else { store.beginCompose(replyTo: message) }
                }))
            }
            if store.canMoveSelected(to: .archive) {
                result.append(Action(id: "archive", title: "Archive message", symbol: "archivebox", shortcut: "⇧⌘A", run: { store.archiveSelected() }))
            }
            if store.canMoveSelected(to: .trash) {
                result.append(Action(id: "trash", title: "Move to Trash", symbol: "trash", shortcut: "⌘⌫", run: { store.deleteSelected() }))
            }
            result.append(Action(id: "read", title: message.isUnread ? "Mark as read" : "Mark as unread", symbol: "envelope", shortcut: "⇧⌘U", run: { store.setRead(message.isUnread, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }))
            result.append(Action(id: "star", title: message.isStarred ? "Remove star" : "Star message", symbol: "star", shortcut: "⇧⌘L", run: { store.setStarred(!message.isStarred, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }))
            if !message.isDraft && message.mailbox != .outbox {
                result.append(Action(id: "needsReply", title: message.workflow.needsReply ? "Mark conversation done" : "Add to Needs Reply", symbol: "arrowshape.turn.up.left", run: { store.setNeedsReply(!message.workflow.needsReply, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }))
                if store.selectedMessageIDs.count <= 1 {
                    result.append(Action(id: "snooze", title: "Snooze conversation…", symbol: "moon.zzz", run: { runtime.schedulePurpose = .snooze }))
                    result.append(Action(id: "followUp", title: "Set follow-up reminder…", symbol: "bell", run: { runtime.schedulePurpose = .followUp }))
                    result.append(Action(id: "note", title: "Edit private note…", symbol: "note.text", run: { runtime.showsPrivateNote = true }))
                }
            }
        }
        if store.canUndoSend {
            result.append(Action(id: "undoSend", title: "Undo Send", symbol: "arrow.uturn.backward", run: store.undoLastSend))
        }
        for mailbox in Mailbox.allCases {
            result.append(Action(id: "mailbox-\(mailbox.rawValue)", title: "Go to \(mailbox.title)", symbol: mailbox.systemImage, run: { store.selectMailbox(mailbox) }))
        }
        for view in store.savedViews {
            result.append(Action(id: "view-\(view.id)", title: "Open \(view.name)", symbol: "line.3.horizontal.decrease.circle", run: { store.selectSavedView(view) }))
        }
        for split in store.visibleInboxSplits {
            result.append(Action(id: "split-\(split.id)", title: "Open \(split.name) inbox", symbol: "tray", run: { store.selectInboxSplit(split.id) }))
        }
        result.append(Action(id: "organizeInbox", title: "Manage inbox tabs and VIPs…", symbol: "line.3.horizontal.decrease.circle", run: { runtime.showsInboxManager = true }))
        result.append(Action(id: "saveView", title: "Save current inbox view…", symbol: "plus.rectangle.on.folder", run: { runtime.showsSavedViewEditor = true }))
        result.append(Action(id: "attachments", title: "Open attachment library", symbol: "paperclip", run: { runtime.showsAttachmentLibrary = true }))
        result.append(Action(id: "calendar", title: "Open calendar", symbol: "calendar", shortcut: "⌥⌘C", run: { runtime.showsCalendar = true }))
        result.append(Action(id: "askMail", title: "Ask your mail…", symbol: "sparkles", run: { runtime.showsAIQuestion = true }))
        if runtime.backend.isConnected {
            result.append(Action(id: "workspace", title: "Open workspace and team templates…", symbol: "bubble.left.and.bubble.right", run: { runtime.showsWorkspace = true }))
            if !runtime.isSyncingBackend {
                result.append(Action(id: "sync", title: "Sync mail", symbol: "arrow.clockwise", run: { Task { await runtime.sync() } }))
            }
        }
        result.append(Action(id: "accounts", title: runtime.backend.isConnected ? "Add or manage email accounts…" : "Sign in to workspace…", symbol: "person.crop.circle", run: {
            settingsTab = "accounts"
            openSettings()
        }))
        result.append(Action(id: "settings", title: "Open settings", symbol: "gearshape", shortcut: "⌘,", run: { openSettings() }))
        return result.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PostmereIcon("magnifyingglass", size: 16).foregroundStyle(PostmereTheme.icon)
                TextField("Search commands and mailboxes", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .onSubmit(executeSelection)
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                Text("esc").font(.caption).foregroundStyle(.tertiary)
            }.padding(20)
            Divider()
            if actions.isEmpty {
                PostmereSearchEmptyState(query: query) {
                    query = ""
                    searchFocused = true
                }.frame(height: 330)
            } else {
                List(actions, selection: $selection) { action in
                    HStack(spacing: 12) {
                        PostmereIcon(action.symbol, size: 16).frame(width: 22)
                            .foregroundStyle(selection == action.id ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(PostmereTheme.icon))
                        Text(action.title)
                        Spacer()
                        Text(action.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(action.id).contentShape(Rectangle())
                        .onTapGesture { execute(action) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(action.title)
                        .accessibilityHint(action.shortcut.isEmpty ? "Run command" : "Shortcut \(action.shortcut)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { execute(action) }
                }.listStyle(.inset).frame(height: 330)
                    .onSubmit(executeSelection)
            }
            HStack {
                Text("↑ ↓ to navigate · Return to run").foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.font(.caption).padding(12)
        }.frame(width: 540)
            .onAppear { searchFocused = true; selection = actions.first?.id }
            .onChange(of: query) { selection = actions.first?.id }
    }

    private func moveSelection(_ offset: Int) {
        guard !actions.isEmpty else { return }
        let index = actions.firstIndex { $0.id == selection } ?? 0
        selection = actions[max(0, min(actions.count - 1, index + offset))].id
    }

    private func executeSelection() {
        if let action = actions.first(where: { $0.id == selection }) ?? actions.first { execute(action) }
    }

    private func execute(_ action: Action) {
        runtime.pendingPaletteAction = action.run
        dismiss()
    }
}
