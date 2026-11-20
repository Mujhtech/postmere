import AppKit
import AppIntents
import Observation
import UserNotifications

@MainActor
@Observable
final class MailRuntime {
    let store: MailStore
    let backend = BackendSession()
    let defaultMail: DefaultMailAppService
    @ObservationIgnored let absentSenderMarks: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 1_000
        return cache
    }()
    let mailboxCounts: MailboxCounts
    let notifications = MailNotificationService()
    let push = MailPushService()
    var shouldFocusMailSearch = false
    var showsCommandPalette = false
    var showsAttachmentLibrary = false
    var showsSavedViewEditor = false
    var showsInboxManager = false
    var showsCalendar = false
    var showsAIQuestion = false
    var showsWorkspace = false
    var activeSharedReplyID: UUID?
    var activeSharedReplyScope: String?
    private var lastSharedPresenceRefresh = Date.distantPast
    private var isRefreshingSharedPresence = false
    var schedulePurpose: MailSchedulePurpose? {
        didSet { if schedulePurpose != nil { scheduleTarget = store.selectedMessage } }
    }
    private(set) var scheduleTarget: MailMessage?
    var showsPrivateNote = false {
        didSet { if showsPrivateNote { privateNoteTarget = store.selectedMessage } }
    }
    private(set) var privateNoteTarget: MailMessage?
    @ObservationIgnored var pendingPaletteAction: (() -> Void)?
    @ObservationIgnored var openMailWindow: (() -> Void)?
    private var lastAccessibleWorkspaceScope: String?
    private var suspendedComposerScope: String?
    private var started = false
    var isSyncingBackend = false
    var backendHasMore = false
    var backendSearchCursor: String?
    var mailSyncActivity: MailSyncActivity = .idle
    @ObservationIgnored var pendingMailSync: BackendMailSyncDemand = []
    @ObservationIgnored var mailSyncGeneration: UUID?
    @ObservationIgnored var nextMailCacheCheck = Date.distantPast
    @ObservationIgnored var nextAccountCatalogCheck = Date.distantPast
    var lastMailSyncError: String?
    @ObservationIgnored var mailSyncRateLimit: Date?
    @ObservationIgnored var mailSyncStatuses: [UUID: BackendMailSyncStatus] = [:]
    @ObservationIgnored var isSearchingBackend = false
    var backendSearchContext: BackendSearchContext?
    var isProcessingBackendOutbox = false
    var lastBackendOutboxRefresh = Date.distantPast
    var submittingBackendItems: Set<UUID> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let realtime = BackendRealtimeCoordinator()
    @ObservationIgnored private var pushRegistrationGeneration: UUID?
    private var pendingPushDestination: MailPushDestination?
    private var isOpeningPushDestination = false
    private var deferredIncomingNotificationIDs: Set<UUID> = []
    private var isFlushingDeferredNotifications = false

    init(store: MailStore? = nil, defaultMail: DefaultMailAppService? = nil) {
        self.defaultMail = defaultMail ?? DefaultMailAppService()
        self.store = store ?? MailStore(openInBackground: true)
        mailboxCounts = MailboxCounts(store: self.store, dockAccounts: { [backend] in
            guard backend.canAccessWorkspace, let scope = backend.scope else { return [] }
            let disconnecting = backend.disconnectingAccountIDs
            return Set(RemoteAccountRegistry.accounts.lazy.filter {
                $0.scope == scope && $0.status == "connected" && !disconnecting.contains($0.accountID)
            }.map(\.localID))
        }, writeBadge: { count in
            let label = count?.formatted()
            if let tile = NSApp?.dockTile, tile.badgeLabel != label { tile.badgeLabel = label }
        })
        backend.pushInstallationID = push.installationID
        backend.onAccountCatalogChanged = { [weak self] in
            PostmereFocusFilter.invalidateFocusFilterAppContext()
            self?.reconcileWorkspaceAccess()
        }
        notifications.shouldNotifyLocally = { [weak self] message in
            self?.push.allowsLocalIncoming(for: message.account) == true
        }
        notifications.shouldDeliverIncoming = { [weak self] message in
            self?.store.permitsIncomingNotification(message) == true
        }
        self.store.onNotificationPolicyChanged = { [weak self] in
            self?.notifications.notificationPolicyChanged()
            Task { await self?.synchronizePush() }
        }
        notifications.onPreferencesChanged = { [weak self] in Task { await self?.synchronizePush() } }
        notifications.validateRemoteDestination = { [weak self] destination in
            self?.validPushDestination(destination) == true
        }
        notifications.shouldPresentRemoteDestination = { [weak self] destination in
            await self?.shouldPresentPush(destination) == true
        }
        notifications.openRemoteMessage = { [weak self] destination in
            self?.pendingPushDestination = destination
            Task { await self?.openPendingPushDestination() }
        }
    }

    func finishPaletteDismissal() {
        let action = pendingPaletteAction
        pendingPaletteAction = nil
        guard backend.canAccessWorkspace else { return }
        action?()
    }

    var canResumeComposer: Bool {
        !store.isComposing || suspendedComposerScope == nil || suspendedComposerScope == backend.scope
    }

    /// Save the current draft, but remove every transient mail presentation
    /// when the workspace session ends. The scene gate removes its view tree.
    func reconcileWorkspaceAccess() {
        mailLinks.useWorkspace(backend.canAccessWorkspace ? backend.scope : nil)
        reconcileRealtime()
        let generation = backend.realtimeGeneration
        push.reset(generation: generation)
        if pushRegistrationGeneration != generation {
            deferredIncomingNotificationIDs = []
            pushRegistrationGeneration = generation
            if generation != nil { NSApp?.registerForRemoteNotifications() }
            else { NSApp?.unregisterForRemoteNotifications() }
        }
        guard !backend.canAccessWorkspace else {
            lastAccessibleWorkspaceScope = backend.scope
            if !store.isComposing || suspendedComposerScope == backend.scope { suspendedComposerScope = nil }
            return
        }
        pendingPaletteAction = nil
        showsCommandPalette = false
        showsAttachmentLibrary = false
        showsSavedViewEditor = false
        showsInboxManager = false
        showsCalendar = false
        showsAIQuestion = false
        showsWorkspace = false
        schedulePurpose = nil
        scheduleTarget = nil
        showsPrivateNote = false
        privateNoteTarget = nil
        activeSharedReplyID = nil
        activeSharedReplyScope = nil
        openMailWindow = nil
        if store.isComposing, suspendedComposerScope == nil {
            suspendedComposerScope = lastAccessibleWorkspaceScope ?? ""
            store.saveDraft()
            if !store.isComposing { suspendedComposerScope = nil }
        } else {
            store.flushPersistence()
        }

        // Native attachment and formatting panels are not owned by a SwiftUI
        // sheet, so dismiss those as the authenticated view is removed.
        for panel in (NSApp?.windows ?? []).compactMap({ $0 as? NSPanel }) {
            if let filePanel = panel as? NSSavePanel { filePanel.cancel(nil) }
            else { panel.orderOut(nil) }
        }
    }

    func start() {
        guard worker == nil else { return }
        worker = Task { await run() }
    }

    func run() async {
        guard !started else { return }
        started = true
        await store.openingTask?.value
        store.onCancelRemoteSend = { [weak self] id in Task { await self?.cancelBackendSend(id) } }
        store.onRetryRemoteSend = { [weak self] id in Task { await self?.retryBackendSend(id) } }
        store.remoteMutation = { [weak self] before, after in
            guard let self else { throw MailStorageError.missingSender }
            try await self.mutateBackendMessage(before: before, after: after)
        }

        notifications.openMessage = { [weak self] id in self?.openMessage(id) }
        store.onSnoozeDue = { [weak self] message, date in
            Task { await self?.notifications.notifySnoozeDue(message, originalDate: date) }
        }
        Task { await backend.retryPendingRevocations(force: true) }
        await backend.restore()
        await notifications.refreshAuthorization()
        while !Task.isCancelled {
            Task { await backend.retryPendingRevocations() }
            await backend.retrySavedSession()
            await backend.expireSessionIfNeeded()
            reconcileRealtime()
            if backend.canAccessWorkspace && !isSyncingBackend && Date.now >= nextMailCacheCheck {
                Task { await syncBackend(refreshProvider: false, refreshAccounts: Date.now >= nextAccountCatalogCheck) }
            }
            if backend.canAccessWorkspace {
                Task { await synchronizePush() }
                Task { await openPendingPushDestination() }
                Task { await store.processDueWork() }
                Task { await processBackendOutbox() }
                await refreshSharedPresence()
            }
            await notifications.reconcileReminders(messages: store.messages, revision: store.mailboxDataRevision)
            do { try await Task.sleep(for: .seconds(1)) }
            catch { break }
        }
        started = false
        realtime.update(generation: nil, connect: { _, _ in }, refresh: { _ in })
    }

    func synchronizePush(forceStatus: Bool = false) async {
        notifications.reconcileAccounts()
        guard notifications.hasCheckedAuthorization else { return }
        let preferences = MailPushPreferences.workspace(accounts: RemoteAccountRegistry.accounts, profiles: notifications.profiles,
            authorized: notifications.isAuthorized, senderScreeningEnabled: store.senderScreeningEnabled, senderRules: store.senderRules)
        await push.synchronize(session: backend, preferences: preferences, forceStatus: forceStatus)
        await flushDeferredIncomingNotifications()
    }

    func notifyBackendMessage(_ message: MailMessage) async {
        guard push.hasResolvedDeliveryOwnership else {
            deferredIncomingNotificationIDs.insert(message.id)
            return
        }
        deferredIncomingNotificationIDs.remove(message.id)
        await notifications.notifyNewMessage(message)
    }

    private func flushDeferredIncomingNotifications() async {
        guard !isFlushingDeferredNotifications, !deferredIncomingNotificationIDs.isEmpty,
              push.hasResolvedDeliveryOwnership, let generation = backend.realtimeGeneration else { return }
        isFlushingDeferredNotifications = true
        defer { isFlushingDeferredNotifications = false }
        let pending = deferredIncomingNotificationIDs
        let known = Set(store.messages.map(\.id)).subtracting(pending)
        for account in RemoteAccountRegistry.accounts {
            for message in store.backendNotificationCandidates(for: account, excluding: known) {
                guard backend.realtimeGeneration == generation, push.hasResolvedDeliveryOwnership else { return }
                await notifyBackendMessage(message)
            }
        }
        if backend.realtimeGeneration == generation {
            // Entries read, removed or screened while registration was offline
            // are deliberately dropped instead of reviving an old alert.
            deferredIncomingNotificationIDs.subtract(pending)
        }
    }

    func registeredForPush(token: Data) {
        push.registered(token: token)
        Task { await synchronizePush() }
    }

    func receivedPush(_ destination: MailPushDestination) {
        guard validPushDestination(destination) else { return }
        Task { await syncBackend(refreshProvider: false) }
    }

    private func validPushDestination(_ destination: MailPushDestination) -> Bool {
        guard backend.canAccessWorkspace, let credential = backend.credential,
              let account = RemoteAccountRegistry.accounts.first(where: { $0.accountID == destination.accountID }),
              backend.isAccountConnected(account.accountID, scope: account.scope) else { return false }
        return destination.matches(credential, account: account)
    }

    private func shouldPresentPush(_ destination: MailPushDestination) async -> Bool {
        guard validPushDestination(destination), push.remoteAccountIDs.contains(destination.filterCriteria) else { return false }
        let generation = backend.realtimeGeneration
        if !store.messages.contains(where: { $0.backendMessageID == destination.messageID && $0.account == destination.filterCriteria }) {
            do {
                guard let account = RemoteAccountRegistry.accounts.first(where: { $0.localID == destination.filterCriteria }) else { return false }
                _ = try await fetchProviderMessage(destination.messageID, for: account)
            } catch { return false }
        }
        guard backend.realtimeGeneration == generation, validPushDestination(destination),
              push.remoteAccountIDs.contains(destination.filterCriteria),
              let message = store.messages.first(where: { $0.backendMessageID == destination.messageID && $0.account == destination.filterCriteria }) else { return false }
        return store.permitsIncomingNotification(message)
    }

    private func openPendingPushDestination() async {
        guard !isOpeningPushDestination, let destination = pendingPushDestination,
              backend.canAccessWorkspace else { return }
        guard validPushDestination(destination) else { pendingPushDestination = nil; return }
        let generation = backend.realtimeGeneration
        isOpeningPushDestination = true
        defer { isOpeningPushDestination = false }
        do {
            if !store.messages.contains(where: { $0.backendMessageID == destination.messageID && $0.account == destination.filterCriteria }) {
                guard let account = RemoteAccountRegistry.accounts.first(where: { $0.localID == destination.filterCriteria }) else { return }
                _ = try await fetchProviderMessage(destination.messageID, for: account)
            }
            guard backend.realtimeGeneration == generation, validPushDestination(destination),
                  let message = store.messages.first(where: { $0.backendMessageID == destination.messageID && $0.account == destination.filterCriteria }) else { return }
            pendingPushDestination = nil
            openMessage(message.id)
        } catch {
            if backend.realtimeGeneration == generation { pendingPushDestination = nil; store.operationError = "This notification’s message could not be opened. Refresh your mail and try again." }
        }
    }

    private func reconcileRealtime() {
        let requestGeneration = backend.realtimeGeneration
        realtime.update(generation: requestGeneration, connect: { [weak self] cursor, receive in
            guard let self, self.backend.realtimeGeneration == requestGeneration else { throw CancellationError() }
            try await self.backend.receiveEvents(lastEventID: cursor, receive: receive)
        }, refresh: { [weak self] changes in
            guard let self else { return }
            guard !Task.isCancelled, self.backend.realtimeGeneration == requestGeneration else { return }
            if !changes.intersection([.mail, .accounts]).isEmpty {
                await self.syncBackend(refreshProvider: false, refreshAccounts: changes.contains(.accounts))
            }
            guard !Task.isCancelled, self.backend.realtimeGeneration == requestGeneration else { return }
            if changes.contains(.outbox) { await self.processBackendOutbox(forceRefresh: true) }
        })
    }

    func refreshSharedPresence(force: Bool = false) async {
        guard !isRefreshingSharedPresence, let id = activeSharedReplyID else { return }
        guard backend.isConnected, activeSharedReplyScope == backend.scope else {
            activeSharedReplyID = nil
            activeSharedReplyScope = nil
            return
        }
        guard force || !store.isComposing || Date.now.timeIntervalSince(lastSharedPresenceRefresh) >= 20 else { return }
        isRefreshingSharedPresence = true
        defer { isRefreshingSharedPresence = false }
        lastSharedPresenceRefresh = .now
        let active = store.isComposing
        let _: BackendEmpty? = try? await backend.request("PUT", "/v1/shared/threads/\(id.uuidString)/presence", body: SharedPresenceInput(active: active))
        if !active, activeSharedReplyID == id {
            activeSharedReplyID = nil
            activeSharedReplyScope = nil
        }
    }

    func sync() async {
        guard backend.canAccessWorkspace else { return }
        await syncBackend()
    }

    func openMessage(_ id: UUID) {
        guard backend.canAccessWorkspace,
              let message = store.messages.first(where: { $0.id == id }), store.isAccountVisible(message) else { return }
        store.selectMailbox(message.mailbox)
        store.select(message)
        openMailWindow?()
    }

    func resolveAttachment(_ attachment: MailAttachment, in message: MailMessage) async throws -> MailAttachment {
        guard backend.canAccessWorkspace else { throw BackendError.notConnected }
        let scope = backend.scope
        if let url = attachment.localURL, FileManager.default.fileExists(atPath: url.path) { return attachment }
        guard message.mailAccount.isRemote else {
            throw BackendError.response(400, "This cached attachment is not stored on this Mac. Connect this email account through your workspace to retrieve a current copy.")
        }
        let resolved = try await resolveBackendAttachment(attachment, in: message)
        guard backend.canAccessWorkspace, backend.scope == scope else { throw BackendError.notConnected }
        return resolved
    }
}
