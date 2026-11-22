import Foundation
import Observation

/// Keeps the Dock, sidebar, and menu bar up to date even while the mail window is closed.
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

    var menuBarInbox: MenuBarInbox? {
        guard !store.isOpeningMailbox, let inbox = snapshot?.menuBarInbox,
              inbox.accounts == menuAccounts(connected: dockAccounts()) else { return nil }
        return inbox
    }

    private func menuAccounts(connected: Set<String>) -> Set<String> {
        store.isPreview ? connected.union([MailAccount.work.rawValue, MailAccount.personal.rawValue]) : connected
    }

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
        let menuAccounts = menuAccounts(connected: next.dockAccounts)
        request = next
        if snapshot?.accounts != next.accounts { snapshot = nil }
        updateBadge()
        loading?.cancel()
        let messages = store.messages
        guard !next.accounts.isEmpty, !messages.isEmpty else {
            snapshot = SidebarCounts(accounts: next.accounts, menuAccounts: menuAccounts)
            updateBadge()
            return
        }
        loading = Task { [weak self] in
            guard let counts = try? await SidebarCounts.load(messages, accounts: next.accounts, menuAccounts: menuAccounts),
                  !Task.isCancelled, let self, self.currentRequest == next else { return }
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
    var menuBarInbox: MenuBarInbox

    init(accounts: Set<String>, menuAccounts: Set<String>) {
        self.accounts = accounts
        menuBarInbox = MenuBarInbox(accounts: menuAccounts)
    }

    @concurrent static func load(_ messages: [MailMessage], accounts: Set<String>, menuAccounts: Set<String>) async throws -> Self {
        var result = Self(accounts: accounts, menuAccounts: menuAccounts)
        var countedThreads: [Mailbox: Set<String>] = [:]
        var inboxReplyThreads: [String: Int] = [:]
        let mailboxes = Mailbox.allCases
        for (index, message) in messages.enumerated() {
            try Task.checkCancellation()
            guard accounts.contains(message.account),
                  message.providerDeletedAt == nil || message.isDraft || message.mailbox == .outbox else { continue }
            for mailbox in mailboxes where message.belongs(to: mailbox) {
                if mailbox == .inbox {
                    if menuAccounts.contains(message.account) {
                        if message.isUnread { result.menuBarInbox.addUnread(message) }
                        // Needs you: waiting on a reply, or triage marked it as needing you.
                        if message.needsReply || message.triagePriority == "needs_you" {
                            let key = message.searchConversationKey
                            if let prior = inboxReplyThreads[key] {
                                if MenuBarInbox.newer(message, than: messages[prior]) { inboxReplyThreads[key] = index }
                            } else {
                                inboxReplyThreads[key] = index
                            }
                        }
                    }
                    guard message.isUnread else { continue }
                    result.unreadByAccount[message.account, default: 0] += 1
                } else if mailbox.isConversationQueue {
                    guard countedThreads[mailbox, default: []].insert(message.searchConversationKey).inserted else { continue }
                }
                result.mailboxes[mailbox, default: 0] += 1
            }
        }
        for index in inboxReplyThreads.values {
            try Task.checkCancellation()
            result.menuBarInbox.add(messages[index], to: .needsYou)
        }
        return result
    }
}

nonisolated enum MenuBarInboxFilter: String, CaseIterable {
    /// What needs you comes right after All; automated updates last.
    case all, needsYou, people, updates
}

/// What a menu bar row can do without opening Postmere.
enum MenuBarRowAction {
    /// Mark read, or done in Needs you.
    case clear
    case archive
    case snooze(Date)
}

/// Unread filters count individual messages. The reply queue counts one task per inbox conversation.
nonisolated struct MenuBarInbox: Sendable {
    let accounts: Set<String>
    private static let people = MailSearchQuery(source: InboxSplit.peopleQuery)
    private static let previewLimit = 6

    private struct Section: Sendable {
        var count = 0
        var messages: [MailMessage] = []

        mutating func add(_ message: MailMessage) {
            count += 1
            if messages.count == previewLimit, let last = messages.last {
                guard MenuBarInbox.newer(message, than: last) else { return }
                messages.removeLast()
            }
            let position = messages.firstIndex { MenuBarInbox.newer(message, than: $0) } ?? messages.endIndex
            messages.insert(message, at: position)
        }
    }
    private var sections: [MenuBarInboxFilter: Section] = [:]

    init(accounts: Set<String>) { self.accounts = accounts }

    func count(for filter: MenuBarInboxFilter) -> Int { sections[filter]?.count ?? 0 }
    func messages(for filter: MenuBarInboxFilter) -> [MailMessage] { sections[filter]?.messages ?? [] }

    fileprivate mutating func addUnread(_ message: MailMessage) {
        add(message, to: .all)
        add(message, to: Self.people.matches(message) ? .people : .updates)
    }

    fileprivate static func newer(_ lhs: MailMessage, than rhs: MailMessage) -> Bool {
        if lhs.sentAt == rhs.sentAt { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.sentAt > rhs.sentAt
    }

    fileprivate mutating func add(_ message: MailMessage, to filter: MenuBarInboxFilter) {
        sections[filter, default: Section()].add(message)
    }
}
