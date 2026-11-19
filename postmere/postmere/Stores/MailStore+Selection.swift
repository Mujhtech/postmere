import Foundation

extension MailStore {
    var selectedMessages: [MailMessage] { filteredMessages.filter { selectedMessageIDs.contains($0.id) } }

    func setSelection(_ ids: Set<UUID>) {
        let visible = filteredMessages
        let added = ids.subtracting(selectedMessageIDs)
        selectedMessageIDs = ids.intersection(Set(visible.map(\.id)))
        isUpdatingSelection = true
        if let newest = visible.first(where: { added.contains($0.id) }) {
            selectedMessageID = newest.id
        } else if selectedMessageID.map({ selectedMessageIDs.contains($0) }) != true {
            selectedMessageID = visible.first(where: { selectedMessageIDs.contains($0.id) })?.id
        }
        isUpdatingSelection = false
        if selectedMessageIDs.count == 1 { markSelectedRead() }
    }

    @discardableResult
    func moveMessages(_ ids: Set<UUID>, to mailbox: Mailbox) -> Bool {
        let original = messages.filter { ids.contains($0.id) && canMoveMessage($0, to: mailbox) }
        let movable = original.map(\.id)
        persistenceSuspended += 1
        for id in movable { moveMessage(id, to: mailbox) }
        persistenceSuspended -= 1
        persistState()
        reconcileSelection()
        if movable.count > 1 {
            batchMoveUndo = original
            batchMoveSelection = ids
            announceMove("Moved \(movable.count) messages to \(mailbox.title)")
        }
        return !movable.isEmpty
    }

    @discardableResult
    func restoreMessages(_ ids: Set<UUID>) -> Bool {
        let originals = messages.filter { ids.contains($0.id) && $0.mailbox == .trash }
        guard !originals.isEmpty else { return false }
        persistenceSuspended += 1
        for message in originals { restoreMessage(message.id) }
        persistenceSuspended -= 1
        persistState()
        reconcileSelection()
        if originals.count > 1 {
            batchMoveUndo = originals
            batchMoveSelection = ids
            announceMove("Restored \(originals.count) messages")
        }
        return true
    }

    func undoBatchMove() -> Bool {
        guard let originals = batchMoveUndo else { return false }
        let before = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
        var updated = messages
        for index in updated.indices {
            guard let old = before[updated[index].id] else { continue }
            updated[index].mailbox = old.mailbox
            updated[index].trashedFrom = old.trashedFrom
            updated[index].isUnread = old.isUnread
        }
        messages = updated
        setSelection(batchMoveSelection)
        batchMoveUndo = nil
        batchMoveSelection = []
        lastAction = "Batch move undone"
        return true
    }

    func setRead(_ read: Bool, for ids: Set<UUID>) {
        batchMoveUndo = nil
        var updated = messages
        for index in updated.indices where ids.contains(updated[index].id) { updated[index].isUnread = !read }
        messages = updated
        reconcileSelection()
        lastAction = read ? "Marked selected messages as read" : "Marked selected messages as unread"
    }

    func setStarred(_ starred: Bool, for ids: Set<UUID>) {
        batchMoveUndo = nil
        var updated = messages
        for index in updated.indices where ids.contains(updated[index].id) { updated[index].isStarred = starred }
        messages = updated
        reconcileSelection()
        lastAction = starred ? "Starred selected messages" : "Removed selected stars"
    }

    func setNeedsReply(_ needsReply: Bool, for ids: Set<UUID>) {
        persistenceSuspended += 1
        let selected = messages.filter { ids.contains($0.id) && !$0.isDraft && $0.mailbox != .outbox }
        var handled: Set<String> = []
        for message in selected where handled.insert(conversationKey(for: message)).inserted {
            setNeedsReply(needsReply, for: message.id)
        }
        persistenceSuspended -= 1
        persistState()
    }
}
