import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Private to Postmere: dragged messages never land in other apps as text.
    nonisolated static let postmereMessages = UTType(exportedAs: "mujhtech.postmere.messages")
}

/// Messages dragged from the list onto a mailbox or label in the sidebar.
nonisolated struct DraggedMessages: Codable, Transferable, Sendable {
    let ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .postmereMessages)
    }
}

extension MailStore {
    /// Mailboxes in the sidebar that accept dropped messages.
    static let dropMailboxes: Set<Mailbox> = [.inbox, .starred, .needsReply, .archive, .junk, .trash]

    /// Dragging a row that is part of a multiple selection drags the selection.
    func draggedMessageIDs(from id: UUID) -> [UUID] {
        selectedMessageIDs.count > 1 && selectedMessageIDs.contains(id) ? Array(selectedMessageIDs) : [id]
    }

    /// Moves, stars or flags dropped messages. Messages the mailbox cannot
    /// take, such as a sent message dropped on Junk, are left where they are.
    @discardableResult
    func drop(_ ids: [UUID], on mailbox: Mailbox) -> Bool {
        let dropped = Set(ids)
        let messages = messages.filter { dropped.contains($0.id) }
        switch mailbox {
        case .inbox, .archive, .junk, .trash:
            let movable = Set(messages.filter { canMoveMessage($0, to: mailbox) }.map(\.id))
            return !movable.isEmpty && moveMessages(movable, to: mailbox)
        case .starred:
            let unstarred = Set(messages.filter { !$0.isStarred && $0.mailbox != .outbox }.map(\.id))
            guard !unstarred.isEmpty else { return false }
            setStarred(true, for: unstarred)
            return true
        case .needsReply:
            let open = Set(messages.filter { $0.allowsWorkflowActions && !$0.needsReply }.map(\.id))
            guard !open.isEmpty else { return false }
            setNeedsReply(true, for: open)
            return true
        default:
            return false
        }
    }
}
