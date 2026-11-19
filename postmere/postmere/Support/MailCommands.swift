import SwiftUI
import AppKit

struct MailStoreKey: FocusedValueKey { typealias Value = MailStore }
struct ComposerWindowKey: FocusedValueKey { typealias Value = Bool }
struct ComposeFormattingKey: FocusedValueKey { typealias Value = ComposeTextFormatting }

extension FocusedValues {
    var mailStore: MailStore? {
        get { self[MailStoreKey.self] }
        set { self[MailStoreKey.self] = newValue }
    }
    var isComposerWindow: Bool? {
        get { self[ComposerWindowKey.self] }
        set { self[ComposerWindowKey.self] = newValue }
    }
    var composeFormatting: ComposeTextFormatting? {
        get { self[ComposeFormattingKey.self] }
        set { self[ComposeFormattingKey.self] = newValue }
    }
}

struct MailCommands: Commands {
    @FocusedValue(\.mailStore) private var focusedStore
    @FocusedValue(\.isComposerWindow) private var isComposerWindow
    @FocusedValue(\.composeFormatting) private var formatting
    @Environment(\.openWindow) private var openWindow
    private let sharedStore: MailStore
    private let runtime: MailRuntime

    init(store: MailStore, runtime: MailRuntime) { sharedStore = store; self.runtime = runtime }

    private var canAccessWorkspace: Bool { runtime.backend.canAccessWorkspace }
    private var store: MailStore? { canAccessWorkspace ? focusedStore ?? sharedStore : nil }

    private var canActOnMessage: Bool {
        canAccessWorkspace && focusedStore?.selectedMessage != nil && isComposerWindow != true
    }
    private var canActOnConversation: Bool { canActOnMessage && (store?.selectedMessageIDs.count ?? 0) <= 1 && store?.selectedMessage?.mailbox != .outbox }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Mail") {
                if let search = NSApp.keyWindow?.toolbar?.visibleItems?.compactMap({ $0 as? NSSearchToolbarItem }).first {
                    search.beginSearchInteraction()
                } else {
                    if focusedStore == nil { openWindow(id: "mail") }
                    runtime.shouldFocusMailSearch = true
                }
            }
            .keyboardShortcut("f")
            .disabled(!canAccessWorkspace || isComposerWindow == true)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                guard canAccessWorkspace else { return }
                store?.beginCompose()
                openWindow(id: "compose")
            }
                .keyboardShortcut("n")
                .disabled(!canAccessWorkspace || MailAccount.sendingAccounts.isEmpty)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Draft") { store?.saveDraft() }
                .keyboardShortcut("s")
                .disabled(!canAccessWorkspace || isComposerWindow != true || store?.isComposing != true)
        }
        CommandGroup(after: .saveItem) {
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
        }
        CommandMenu("Message") {
            Group {
                Button("Command Palette…") { runtime.showsCommandPalette = true; openWindow(id: "mail") }
                    .keyboardShortcut("k")
                Button("Attachment Library…") { runtime.showsAttachmentLibrary = true; openWindow(id: "mail") }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button("Calendar…") { runtime.showsCalendar = true; openWindow(id: "mail") }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Ask Your Mail…") { runtime.showsAIQuestion = true; openWindow(id: "mail") }
                    .keyboardShortcut("j", modifiers: [.command, .option])
                Button("Sync Mail") { Task { await runtime.sync() } }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(!runtime.backend.isConnected || runtime.isSyncingBackend)
                Button("Workspace…") { runtime.showsWorkspace = true; openWindow(id: "mail") }
                Divider()
                Button(store?.selectedMessage?.isDraft == true ? "Edit Draft" : "Reply") {
                    guard let message = store?.selectedMessage else { return }
                    if message.mailbox == .drafts { store?.beginEditingDraft(message) }
                    else { store?.beginCompose(replyTo: message) }
                }
                .keyboardShortcut("r")
                .disabled(!canActOnConversation || store?.isComposing == true || (MailAccount.sendingAccounts.isEmpty && store?.selectedMessage?.isDraft != true) || store?.selectedMessage?.mailbox == .outbox || (store?.selectedMessage?.isDraft == true && store?.selectedMessage?.mailbox == .trash))
                Button("Reply All") {
                    if let message = store?.selectedMessage { store?.beginReplyAll(message) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!canActOnConversation || MailAccount.sendingAccounts.isEmpty || store?.isComposing == true || store?.selectedMessage?.isDraft == true || store?.selectedMessage?.mailbox == .outbox || store?.selectedMessage.map { store?.hasReplyAllRecipients(for: $0) == true } != true)
                Button("Forward") {
                    if let message = store?.selectedMessage { store?.beginForward(message) }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!canActOnConversation || MailAccount.sendingAccounts.isEmpty || store?.isComposing == true || store?.selectedMessage?.isDraft == true || store?.selectedMessage?.mailbox == .outbox)
                Divider()
                Button("Archive") { store?.archiveSelected() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!canActOnMessage || store?.canMoveSelected(to: .archive) != true)
                Button("Move to Trash") { store?.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!canActOnMessage || store?.canMoveSelected(to: .trash) != true)
                Menu("Move to") {
                    ForEach([Mailbox.inbox, .archive, .trash]) { destination in
                        Button(destination.title) { store?.moveSelected(to: destination) }
                            .disabled(!canActOnMessage || store?.canMoveSelected(to: destination) != true)
                    }
                }
                Button("Restore from Trash") { store?.restoreSelected() }
                    .disabled(!canActOnMessage || store?.selectedMessage?.mailbox != .trash)
                Button("Undo Last Move") { store?.undoLastMove() }
                    .disabled(isComposerWindow == true || focusedStore == nil || store?.canUndoMove != true)
                Divider()
                Button(store?.selectedMessage?.isUnread == true ? "Mark as Read" : "Mark as Unread") {
                    if let store, let message = store.selectedMessage { store.setRead(message.isUnread, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!canActOnMessage)
                Divider()
                Button(store?.selectedMessage?.workflow.needsReply == true ? "Mark Conversation Done" : "Needs Reply") {
                    if let store, let message = store.selectedMessage { store.setNeedsReply(!message.workflow.needsReply, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }
                }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!canActOnMessage || store?.selectedMessage?.isDraft == true)
                Button("Snooze…") { runtime.schedulePurpose = .snooze }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!canActOnConversation || store?.selectedMessage?.isDraft == true)
                Button("Follow-up Reminder…") { runtime.schedulePurpose = .followUp }.disabled(!canActOnConversation)
                Button("Private Note…") { runtime.showsPrivateNote = true }.disabled(!canActOnConversation)
                Button("Save Inbox View…") { runtime.showsSavedViewEditor = true }.disabled(isComposerWindow == true)
                Divider()
                Button("Undo Send", action: sharedStore.undoLastSend).disabled(!sharedStore.canUndoSend)
                Button(store?.selectedMessage?.isStarred == true ? "Remove Star" : "Star Message") {
                    if let store, let message = store.selectedMessage { store.setStarred(!message.isStarred, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!canActOnMessage)
            }
            .disabled(!canAccessWorkspace)
        }
        CommandMenu("Inbox") {
            Group {
                Button("All") { sharedStore.selectInboxSplit(nil) }
                    .keyboardShortcut("1").disabled(isComposerWindow == true)
                ForEach(Array((canAccessWorkspace ? sharedStore.visibleInboxSplits : []).prefix(8).enumerated()), id: \.element.id) { index, split in
                    Button(split.name) { sharedStore.selectInboxSplit(split.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 2))))
                        .disabled(isComposerWindow == true)
                }
                Divider()
                Button("Manage Tabs and VIPs…") { runtime.showsInboxManager = true; openWindow(id: "mail") }
            }
            .disabled(!canAccessWorkspace)
        }
        CommandMenu("Format") {
            Group {
                Button("Bold") { formatting?.toggleBold() }
                    .keyboardShortcut("b")
                    .disabled(isComposerWindow != true || formatting == nil)
                Button("Italic") { formatting?.toggleItalic() }
                    .keyboardShortcut("i")
                    .disabled(isComposerWindow != true || formatting == nil)
                Button("Underline") { formatting?.toggleUnderline() }
                    .keyboardShortcut("u")
                    .disabled(isComposerWindow != true || formatting == nil)
            }
            .disabled(!canAccessWorkspace)
        }
    }
}
