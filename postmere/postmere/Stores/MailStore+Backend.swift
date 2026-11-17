import Foundation

extension MailStore {
    /// Establish once, before the account's first network sync. Paging older
    /// history and replaying a retired cursor must not redefine what is new.
    /// Keeping this date across launches still admits mail received while the
    /// Mac was closed, including arrivals in the first response after setup.
    func prepareBackendNotifications(for identity: RemoteAccountIdentity, now: Date = .now) -> Bool {
        guard backendNotificationCutoffs[identity.localID] == nil else { return true }
        backendNotificationCutoffs[identity.localID] = now
        guard persistState() else {
            backendNotificationCutoffs[identity.localID] = nil
            return false
        }
        return true
    }

    func backendNotificationCandidates(for identity: RemoteAccountIdentity, excluding known: Set<UUID>) -> [MailMessage] {
        guard let cutoff = backendNotificationCutoffs[identity.localID] else { return [] }
        return messages.filter {
            $0.account == identity.localID && !known.contains($0.id) && $0.sentAt >= cutoff
                && $0.isUnread && !$0.isOutgoing && !$0.isDeletedOnProvider && $0.mailbox == .inbox
                && $0.workflow.screeningState == .accepted
        }
    }

    /// Persist message changes and their resume cursor together so a failed disk
    /// write never skips changes on the next launch.
    func applyBackendPage(_ page: BackendMailPage, identity: RemoteAccountIdentity) -> Bool {
        let oldCursor = backendSyncCursors[identity.localID]
        persistenceSuspended += 1
        mergeIncoming(page.messages.filter { $0.accountId == identity.accountID }.map { $0.localMessage(identity: identity) })
        let deleted = Set(page.deletedMessageIds ?? [])
        if !deleted.isEmpty {
            var updated = messages
            for index in updated.indices where updated[index].account == identity.localID {
                if let backendID = updated[index].backendMessageID, deleted.contains(backendID) {
                    updated[index].isDeletedOnProvider = true
                    providerOverrides[updated[index].id] = nil
                }
            }
            suppressRemoteMutations = true
            messages = updated
            suppressRemoteMutations = false
        }
        backendSyncCursors[identity.localID] = page.nextCursor
        persistenceSuspended -= 1
        guard persistState() else {
            backendSyncCursors[identity.localID] = oldCursor
            return false
        }
        reconcileSelection()
        return true
    }
}

