import Foundation

/// Only overlapping requests need ordering. A later fetch starts with no protected label values.
@MainActor final class ProviderPageRead {
    let account: String
    var newerLabels: Set<UUID> = []
    init(account: String) { self.account = account }
}

extension MailStore {
    /// Some providers omit the outbound Message-ID when Sent first syncs. The
    /// acceptance receipt can be the first common key between the two rows.
    func reconcileSentDelivery(_ receipt: MailMessage) {
        guard let providerID = receipt.providerMessageID, !providerID.isEmpty,
              let cached = messages.first(where: {
                  $0.id != receipt.id && $0.account == receipt.account && $0.backendMessageID != nil && $0.providerMessageID == providerID
              }) else { return }
        mergeIncoming([cached])
    }

    func beginProviderPage(for account: String) -> ProviderPageRead {
        let read = ProviderPageRead(account: account)
        activeProviderPages.append(read)
        return read
    }

    func endProviderPage(_ read: ProviderPageRead) {
        activeProviderPages.removeAll { $0 === read }
    }

    func applyProviderLabels(_ updated: BackendMailMessage, messageID: UUID, account: RemoteAccountIdentity) {
        guard updated.accountId == account.accountID,
              let index = messages.firstIndex(where: {
                  $0.id == messageID && $0.account == account.localID && $0.backendMessageID == updated.id
              }) else { return }
        for read in activeProviderPages where read.account == account.localID { read.newerLabels.insert(updated.id) }
        var message = messages[index]
        guard message.providerLabelIDs != updated.providerLabels || message.providerCategories != updated.categories else { return }
        message.providerLabelIDs = updated.providerLabels
        message.providerCategories = updated.categories
        let previousSuppression = suppressRemoteMutations
        suppressRemoteMutations = true
        defer { suppressRemoteMutations = previousSuppression }
        messages[index] = message
    }

    /// Establish once, before the account's first network sync. Paging older
    /// history and replaying a retired cursor must not redefine what is new.
    /// Keeping this date across launches still admits mail received while the
    /// Mac was closed, including arrivals in the first response after setup.
    func prepareBackendNotifications(for identity: RemoteAccountIdentity, now: Date = .now) async -> Bool {
        guard backendNotificationCutoffs[identity.localID] == nil else { return true }
        backendNotificationCutoffs[identity.localID] = now
        guard await persistStateAsync() else {
            if backendNotificationCutoffs[identity.localID] == now { backendNotificationCutoffs[identity.localID] = nil }
            return false
        }
        return true
    }

    func backendNotificationCandidates(for identity: RemoteAccountIdentity, excluding known: Set<UUID>) -> [MailMessage] {
        guard let cutoff = backendNotificationCutoffs[identity.localID] else { return [] }
        return messages.filter {
            !known.contains($0.id) && canNotifyArrival($0, account: identity.localID, since: cutoff)
        }
    }

    private func canNotifyArrival(_ message: MailMessage, account: String, since cutoff: Date) -> Bool {
        message.account == account && message.sentAt >= cutoff && message.isUnread && !message.isOutgoing
            && !message.isDeletedOnProvider && message.mailbox == .inbox && message.workflow.screeningState == .accepted
    }

    /// Recheck the committed rows after the disk write. A user can read, move or remove them while it runs.
    private func committedInsertions(at positions: [(id: UUID, index: Int)]) -> [MailMessage] {
        var candidates: [MailMessage] = []
        var moved: Set<UUID> = []
        for (id, index) in positions {
            if messages.indices.contains(index), messages[index].id == id {
                candidates.append(messages[index])
            } else {
                moved.insert(id)
            }
        }
        if !moved.isEmpty { candidates += messages.filter { moved.contains($0.id) } }
        return candidates
    }

    /// Persist message changes and their resume cursor together so a failed disk
    /// write never skips changes on the next launch.
    func applyBackendPage(_ page: BackendMailPage, identity: RemoteAccountIdentity, read: ProviderPageRead? = nil,
                          isCurrent: () -> Bool = { true }) async -> Bool {
        let pageRead = read ?? beginProviderPage(for: identity.localID)
        defer { if read == nil { endProviderPage(pageRead) } }
        guard pageRead.account == identity.localID, isCurrent(),
              let incoming = try? await page.localMessages(for: identity) else { return false }
        let oldCursor = backendSyncCursors[identity.localID]
        guard await mergeReceivedPage(incoming, deletedIDs: Set(page.deletedMessageIds ?? []),
                                      read: pageRead, trackInsertions: trackInsertions, isCurrent: isCurrent, beforeSave: { messagesChanged, newRows in
            insertions = newRows
            requiresSave = messagesChanged || self.backendSyncCursors[identity.localID] != page.nextCursor
            if self.backendSyncCursors[identity.localID] != page.nextCursor {
                self.backendSyncCursors[identity.localID] = page.nextCursor
            }
        }) else { return false }
        // An empty poll or exact replay should not encode the entire mailbox again.
        guard requiresSave || persistenceError != nil || persistenceBlocked else { return true }
        guard await persistStateAsync() else {
            if backendSyncCursors[identity.localID] == page.nextCursor { backendSyncCursors[identity.localID] = oldCursor }
            return false
        }
        return true
    }
}

