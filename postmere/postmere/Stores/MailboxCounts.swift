import Foundation
import Observation

/// Keeps the Dock and sidebar up to date even while the mail window is closed.
@MainActor @Observable
final class MailboxCounts {
    private struct Request: Equatable {
        let revision: Int
        let accounts: Set<String>
        let dockAccounts: Set<String>
    }

    private static let preference = "showUnreadCountInDock"
    private let store: MailStore
    private let defaults: UserDefaults
    private let dockAccounts: () -> Set<String>
    private let writeBadge: (Int?) -> Void
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var loading: Task<Void, Never>?
    private(set) var snapshot: SidebarCounts?

    var showsUnreadInDock: Bool {
        didSet {
            defaults.set(showsUnreadInDock, forKey: Self.preference)
            updateBadge()
        }
    }

    init(store: MailStore, defaults: UserDefaults = .standard,
         dockAccounts: @escaping () -> Set<String>, writeBadge: @escaping (Int?) -> Void) {
        self.store = store
        self.defaults = defaults
        self.dockAccounts = dockAccounts
        self.writeBadge = writeBadge
        showsUnreadInDock = defaults.object(forKey: Self.preference) as? Bool ?? true
        observeMailbox()
    }

    private var currentRequest: Request {
        Request(revision: store.mailboxDataRevision, accounts: store.searchableAccounts, dockAccounts: dockAccounts())
    }

    private func observeMailbox() {
        let next = withObservationTracking { currentRequest } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.observeMailbox() }
        }
        guard next != request else { return }
        let recount = next.revision != request?.revision || next.accounts != request?.accounts
        request = next
        if snapshot?.accounts != next.accounts { snapshot = nil }
        updateBadge()
        guard recount else { return }
        loading?.cancel()
        let messages = store.messages
        guard !next.accounts.isEmpty, !messages.isEmpty else {
            snapshot = SidebarCounts(accounts: next.accounts)
            updateBadge()
            return
        }
        loading = Task { [weak self] in
            guard let counts = try? await SidebarCounts.load(messages, accounts: next.accounts),
                  !Task.isCancelled, let self, self.store.mailboxDataRevision == next.revision,
                  self.store.searchableAccounts == next.accounts else { return }
            self.snapshot = counts
            self.updateBadge()
        }
    }

    private func updateBadge() {
        guard showsUnreadInDock, let snapshot else { writeBadge(nil); return }
        let count = dockAccounts().reduce(0) { $0 + snapshot.unreadByAccount[$1, default: 0] }
        writeBadge(count > 0 ? count : nil)
    }
}

nonisolated struct SidebarCounts: Sendable {
    let accounts: Set<String>
    var mailboxes: [Mailbox: Int] = [:]
    var unreadByAccount: [String: Int] = [:]

    @concurrent static func load(_ messages: [MailMessage], accounts: Set<String>) async throws -> Self {
        var result = Self(accounts: accounts)
        var countedThreads: [Mailbox: Set<String>] = [:]
        let mailboxes = Mailbox.allCases
        for message in messages {
            try Task.checkCancellation()
            guard accounts.contains(message.account),
                  message.providerDeletedAt == nil || message.isDraft || message.mailbox == .outbox else { continue }
            for mailbox in mailboxes where message.belongs(to: mailbox) {
                if mailbox == .inbox {
                    guard message.isUnread else { continue }
                    result.unreadByAccount[message.account, default: 0] += 1
                } else if mailbox.isConversationQueue {
                    guard countedThreads[mailbox, default: []].insert(message.searchConversationKey).inserted else { continue }
                }
                result.mailboxes[mailbox, default: 0] += 1
            }
        }
        return result
    }
}
