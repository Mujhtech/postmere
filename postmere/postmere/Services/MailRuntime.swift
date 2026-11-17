import AppKit
import Observation

@MainActor
@Observable
final class MailRuntime {
    let store: MailStore
    let backend = BackendSession()
    let notifications = MailNotificationService()
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
    private var started = false
    var isSyncingBackend = false
    var backendHasMore = false
    var backendSearchCursor: String?
    var lastBackendSync = Date.distantPast
    var lastBackendSyncScope: String?
    var backendSearchContext: BackendSearchContext?
    var isProcessingBackendOutbox = false
    var lastBackendOutboxRefresh = Date.distantPast
    var submittingBackendItems: Set<UUID> = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(store: MailStore? = nil) { self.store = store ?? MailStore() }

    func finishPaletteDismissal() {
        let action = pendingPaletteAction
        pendingPaletteAction = nil
        action?()
    }

    func start() {
        guard worker == nil else { return }
        worker = Task { await run() }
    }

    func run() async {
        guard !started else { return }
        started = true
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
        await backend.restore()
        await notifications.refreshAuthorization()
        while !Task.isCancelled {
            if backend.isConnected && !isSyncingBackend
                && (backend.scope != lastBackendSyncScope || Date.now.timeIntervalSince(lastBackendSync) >= 60) {
                Task { await sync() }
            }
            store.processWorkflowDates()
            Task { await store.processDueWork() }
            if backend.isConnected { Task { await processBackendOutbox() } }
            await refreshSharedPresence()
            await notifications.reconcileReminders(messages: store.messages)
            do { try await Task.sleep(for: .seconds(1)) }
            catch { break }
        }
        started = false
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

    func sync() async { await syncBackend() }

    func openMessage(_ id: UUID) {
        guard let message = store.messages.first(where: { $0.id == id }), store.isAccountVisible(message) else { return }
        store.selectMailbox(message.mailbox)
        store.select(message)
        openMailWindow?()
    }

    func resolveAttachment(_ attachment: MailAttachment, in message: MailMessage) async throws -> MailAttachment {
        if let url = attachment.localURL, FileManager.default.fileExists(atPath: url.path) { return attachment }
        guard message.mailAccount.isRemote else {
            throw BackendError.response(400, "This cached attachment is not stored on this Mac. Connect this email account through your workspace to retrieve a current copy.")
        }
        return try await resolveBackendAttachment(attachment, in: message)
    }
}
