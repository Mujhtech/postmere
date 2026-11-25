import SwiftUI

/// Something a menu command asks the mailbox screen to do, since only it owns
/// tabs, search and sheets.
enum MobileCommandRequest: Equatable {
    case search, ask, triage, settings, mailboxes, nextMessage, previousMessage, closeMessage
}

/// The iPad menu bar and hardware keyboard shortcuts, matching the Mac's where the
/// same action exists. Hold ⌘ to see them.
struct MobileCommands: Commands {
    let runtime: MailRuntime

    private var store: MailStore { runtime.store }
    private var message: MailMessage? { store.selectedMessage }
    private var canSend: Bool { !MailAccount.sendingAccounts.isEmpty && !store.isComposing }
    private var canAct: Bool { runtime.backend.canAccessWorkspace && message != nil && !store.isComposing }
    private var canReply: Bool {
        canSend && canAct && message?.isDraft == false && message?.mailbox != .outbox
    }

    private func request(_ request: MobileCommandRequest) {
        MobileRouter.shared.command = nil
        MobileRouter.shared.command = request
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { store.beginCompose() }
                .keyboardShortcut("n")
                .disabled(!canSend)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { request(.settings) }
                .keyboardShortcut(",")
        }
        CommandMenu("Mailbox") {
            Button("Search Mail") { request(.search) }
                .keyboardShortcut("f")
            Button("Ask Your Mail…") { request(.ask) }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Button("Start Triage") { request(.triage) }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Mailboxes…") { request(.mailboxes) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Sync Mail") { Task { await runtime.sync() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Inbox") { store.selectMailbox(.inbox) }
                .keyboardShortcut("1")
            Button("Needs Reply") { store.selectMailbox(.needsReply) }
                .keyboardShortcut("2")
            Button("Starred") { store.selectMailbox(.starred) }
                .keyboardShortcut("3")
            Button("Drafts") { store.selectMailbox(.drafts) }
                .keyboardShortcut("4")
            Button("Sent") { store.selectMailbox(.sent) }
                .keyboardShortcut("5")
        }
        CommandMenu("Message") {
            Button("Next Conversation") { request(.nextMessage) }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Previous Conversation") { request(.previousMessage) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            // No bare Escape here: it belongs to text fields and sheets.
            Button("Close Conversation") { request(.closeMessage) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(message == nil)
            Divider()
            Button("Reply") { if let message { store.beginCompose(replyTo: message) } }
                .keyboardShortcut("r")
                .disabled(!canReply)
            Button("Reply All") { if let message { store.beginReplyAll(message) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!canReply || message.map { store.hasReplyAllRecipients(for: $0) } != true)
            Button("Forward") { if let message { store.beginForward(message) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!canReply)
            Divider()
            Button("Archive") { store.archiveSelected() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!canAct || message.map { store.canMoveMessage($0, to: .archive) } != true)
            Button("Move to Trash") { store.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canAct || message.map { store.canMoveMessage($0, to: .trash) } != true)
            Button(message?.isUnread == true ? "Mark as Read" : "Mark as Unread") {
                if let message { store.toggleRead(message.id) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!canAct)
            Button(message?.isStarred == true ? "Remove Star" : "Star") {
                if let message { store.toggleStar(message.id) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!canAct)
            Button(message?.needsReply == true ? "Mark Conversation Done" : "Needs Reply") {
                if let message { store.setNeedsReply(!message.needsReply, for: message.id) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!canAct || message?.allowsWorkflowActions != true)
            Button("Print…") { if let message { MailPrintDocument.present(message) } }
                .keyboardShortcut("p")
                .disabled(message == nil)
            Divider()
            Button("Undo Send", action: store.undoLastSend)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canUndoSend)
        }
    }
}
