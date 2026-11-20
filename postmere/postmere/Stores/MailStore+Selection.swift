import Foundation

extension MailStore {
    /// A menu-bar or notification link can target a message outside the current list.
    @discardableResult
    func revealMessage(_ id: UUID) -> Bool {
        guard let message = messages.first(where: { $0.id == id }), isAccountVisible(message) else { return false }
        clearFilters()
        selectedSavedViewID = nil
        selectedInboxSplitID = nil
        selectedAccount = nil
        selectedMailbox = message.mailbox
        select(message)
        return true
    }

    var selectedMessages: [MailMessage] {
        guard !selectedMessageIDs.isEmpty else { return [] }
        return (mailboxViewData?.messages ?? filteredMessages).filter { selectedMessageIDs.contains($0.id) }
    }

    /// A loading list has no rows to navigate. Small stores without an attached list
    /// still resolve their selection synchronously for programmatic callers.
    var navigableMessages: [MailMessage]? {
        if isSearchActive {
            let rows = activeSearchResults
            return isSearchingMessages && rows.isEmpty ? nil : rows
        }
        if let data = mailboxViewData { return data.messages }
        guard !usesMailboxViewData, !needsBackgroundSearch else { return nil }
        return filteredMessages
    }

    func setSelection(_ ids: Set<UUID>, in scope: MailboxViewScope? = nil) {
        guard scope == nil || scope == mailboxViewKey.scope, let visible = navigableMessages else { return }
        pendingMailboxSelection = nil
        guard !ids.isEmpty else { selectedMessageID = nil; return }
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
        applyMoves(ids, to: mailbox)
    }

    @discardableResult
    func restoreMessages(_ ids: Set<UUID>) -> Bool {
        applyMoves(ids, to: nil)
    }

    /// A nil destination restores each message to the mailbox it was trashed from.
    private func applyMoves(_ ids: Set<UUID>, to mailbox: Mailbox?) -> Bool {
        var updated = messages
        var originals: [MailMessage] = []
        for index in updated.indices where ids.contains(updated[index].id) {
            let original = updated[index]
            let destination: Mailbox
            if let mailbox {
                guard canMoveMessage(original, to: mailbox) else { continue }
                destination = mailbox
            } else {
                guard original.mailbox == .trash else { continue }
                destination = restoreDestination(for: original)
            }
            originals.append(original)
            updated[index].trashedFrom = destination == .trash ? original.mailbox : nil
            updated[index].mailbox = destination
            updated[index].isUnread = false
        }
        guard let first = originals.first else { return false }
        recordMoveUndo(originals)
        pendingMoveSelection = nil
        if !isSearchActive, let lead = selectedMessageID, originals.contains(where: { $0.id == lead }) {
            pendingMoveSelection = (lead, selectedMessageIDs, mailboxViewKey.scope)
        }
        messages = updated
        if !isSearchActive { reconcileSelection() }
        if originals.count == 1 {
            let destination = mailbox ?? restoreDestination(for: first)
            announceMove("Moved to \(destination.title)")
        } else if let mailbox {
            announceMove("Moved \(originals.count) messages to \(mailbox.title)")
        } else {
            announceMove("Restored \(originals.count) messages")
        }
        return true
    }

    func undoBatchMove() -> Bool {
        guard let undo = batchMoveUndo else { return false }
        let before = Dictionary(uniqueKeysWithValues: undo.messages.map { ($0.id, $0) })
        var updated = messages
        for index in updated.indices {
            guard let old = before[updated[index].id] else { continue }
            updated[index].undoMove(to: old)
        }
        if undo.scope == mailboxViewKey.scope {
            isUpdatingSelection = true
            selectedMessageID = undo.lead
            selectedMessageIDs = undo.selection
            isUpdatingSelection = false
        }
        messages = updated
        if !isSearchActive { reconcileSelection() }
        batchMoveUndo = nil
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
        let selected = messages.filter { ids.contains($0.id) && $0.allowsWorkflowActions }
        var handled: Set<String> = []
        for message in selected where handled.insert(conversationKey(for: message)).inserted {
            setNeedsReply(needsReply, for: message.id)
        }
        persistenceSuspended -= 1
        persistState()
    }
}
