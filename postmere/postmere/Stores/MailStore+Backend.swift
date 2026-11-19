import Foundation

/// Only overlapping requests need ordering. A later fetch starts with no protected label values.
@MainActor final class ProviderPageRead {
    let account: String
    var newerLabels: Set<UUID> = []
    init(account: String) { self.account = account }
}

extension MailStore {
    func beginProviderPage(for account: String) -> ProviderPageRead {
        let read = ProviderPageRead(account: account)
        activeProviderPages.append(read)
        return read
    }

    func endProviderPage(_ read: ProviderPageRead) {
        activeProviderPages.removeAll { $0 === read }
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
            $0.account == identity.localID && !known.contains($0.id) && $0.sentAt >= cutoff
                && $0.isUnread && !$0.isOutgoing && !$0.isDeletedOnProvider && $0.mailbox == .inbox
                && $0.workflow.screeningState == .accepted
        }
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
                                      read: pageRead, isCurrent: isCurrent, beforeSave: {
            self.backendSyncCursors[identity.localID] = page.nextCursor
        }) else { return false }
        guard await persistStateAsync() else {
            if backendSyncCursors[identity.localID] == page.nextCursor { backendSyncCursors[identity.localID] = oldCursor }
            return false
        }
        return true
    }
}

