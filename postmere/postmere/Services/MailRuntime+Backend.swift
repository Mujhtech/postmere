import Foundation

extension MailRuntime {
    func syncBackend(_ demand: BackendMailSyncDemand = [.cache, .catalog, .provider]) async {
        guard let generation = backend.realtimeGeneration, let scope = backend.scope else { return }
        if let until = mailSyncRateLimit, until > .now { return }
        pendingMailSync.formUnion(demand)
        // A hint arriving during a read may refer to a later commit. Keep one
        // follow-up read, combining hints from every window, push and the stream.
        guard !isSyncingBackend else { return }
        isSyncingBackend = true
        defer { isSyncingBackend = false }
        repeat {
            let demand = pendingMailSync
            pendingMailSync = []
            mailSyncRateLimit = nil
            do {
                try await readMailCache(demand: demand, generation: generation, scope: scope)
            } catch BackendError.mailSyncRateLimited(let retryAt) {
                guard backend.realtimeGeneration == generation else { return }
                mailSyncRateLimit = retryAt
                nextMailCacheCheck = retryAt
                mailSyncActivity = .waiting(retryAt: retryAt)
                pendingMailSync = []
                return
            } catch {
                guard backend.realtimeGeneration == generation else { return }
                if !Task.isCancelled { reportMailSyncError(error.localizedDescription) }
                nextMailCacheCheck = Date.now.addingTimeInterval(60)
                mailSyncActivity = .idle
                return
            }
        } while !pendingMailSync.isEmpty && !Task.isCancelled && backend.realtimeGeneration == generation
    }

    private func readMailCache(demand: BackendMailSyncDemand, generation: UUID, scope: String) async throws {
        // A push or mail-only event reads the cached mailbox immediately. Catalog
        // changes and explicit refreshes force a lookup. Foreground sync can reuse one.
        var refreshed = false
        if demand.contains(.catalog) || demand.contains(.provider) || backend.accountCatalogState != .loaded {
            refreshed = try await backend.refreshAccountsIfNeeded(force: demand.contains(.catalog))
        }
        guard backend.realtimeGeneration == generation else { return }
        for account in backend.accounts where refreshed || mailSyncStatuses[account.id] == nil {
            mailSyncStatuses[account.id] = account.syncStatus
        }
        let accounts = RemoteAccountRegistry.accounts.filter {
            $0.scope == scope && backend.isAccountConnected($0.accountID, scope: scope)
        }
        let connected = Set(accounts.map(\.accountID))
        mailSyncStatuses = mailSyncStatuses.filter { connected.contains($0.key) }
        if demand.contains(.provider), !accounts.isEmpty { mailSyncActivity = .syncing }

        var remaining = accounts
        var firstPass = true
        var loaded = 0
        var failures: [String] = []
        while !remaining.isEmpty {
            var next: [RemoteAccountIdentity] = []
            for identity in remaining {
                try Task.checkCancellation()
                guard backend.realtimeGeneration == generation else { return }
                guard backend.isAccountConnected(identity.accountID, scope: scope),
                      await store.prepareBackendNotifications(for: identity) else { continue }
                do {
                    let page = try await readMailPage(identity, generation: generation,
                                                      refreshProvider: firstPass && demand.contains(.provider))
                    guard backend.realtimeGeneration == generation else { return }
                    guard let page, backend.isAccountConnected(identity.accountID, scope: scope) else { continue }
                    mailSyncStatuses[identity.accountID] = page.syncStatus
                    loaded += page.messages.count
                    if page.hasMore {
                        next.append(identity)
                        mailSyncActivity = .loadingCache(loaded: loaded)
                    }
                } catch BackendError.response(400, _) where store.backendSyncCursors[identity.localID] != nil {
                    // Retired cursor. Keep local messages while replaying the cache.
                    guard backend.realtimeGeneration == generation else { return }
                    store.backendSyncCursors[identity.localID] = nil
                    if await store.persistStateAsync() { next.append(identity) }
                } catch let error as BackendError {
                    if case .mailSyncRateLimited = error { throw error }
                    if backend.isAccountConnected(identity.accountID, scope: scope) {
                        failures.append("\(identity.email): \(error.localizedDescription)")
                    }
                } catch {
                    try Task.checkCancellation()
                    if backend.isAccountConnected(identity.accountID, scope: scope) {
                        failures.append("\(identity.email): \(error.localizedDescription)")
                    }
                }
            }
            remaining = next
            firstPass = false
            await Task.yield()
        }
        guard backend.realtimeGeneration == generation else { return }
        reportMailSyncError(failures.isEmpty ? nil : failures.joined(separator: "\n"))
        updateMailSyncActivity()
        // The event stream wakes us on commits. This also recovers a silent
        // connection or the end of a worker cooldown that produced no new mail.
        let now = Date.now
        let workerIsActive = mailSyncActivity == .syncing || mailSyncActivity == .importing(cached: nil)
        let fallback = now.addingTimeInterval(workerIsActive || !failures.isEmpty ? 60 : 300)
        nextMailCacheCheck = mailSyncStatuses.values.compactMap(\.retryAt)
            .filter { $0 > now }.min().map { min(fallback, $0) } ?? fallback
    }

    private func readMailPage(_ identity: RemoteAccountIdentity, generation: UUID,
                              refreshProvider: Bool) async throws -> BackendMailPage? {
        func isCurrent() -> Bool {
            !Task.isCancelled && backend.realtimeGeneration == generation
                && backend.isAccountConnected(identity.accountID, scope: identity.scope)
        }
        let cursor = store.backendSyncCursors[identity.localID]
        let read = store.beginProviderPage(for: identity.localID)
        defer { store.endProviderPage(read) }
        let page: BackendMailPage = try await backend.request("POST", "/v1/mail/accounts/\(identity.accountID.uuidString)/sync",
            body: BackendSyncInput(cursor: cursor, refreshProvider: refreshProvider))
        guard isCurrent() else { return nil }
        if !page.messages.isEmpty && mailSyncActivity == .idle { mailSyncActivity = .loadingCache(loaded: 0) }
        var arrivals: [MailMessage] = []
        guard await store.applyBackendPage(page, identity: identity, read: read, isCurrent: isCurrent,
                                          automaticSpamChecksSince: spamChecks.automaticChecksEnabledSince(for: backend),
                                          onSpamCheckArrivals: { self.spamChecks.enqueueIncoming($0, session: self.backend) },
                                          onArrivals: { arrivals = $0 }), isCurrent() else { return nil }
        for message in arrivals {
            guard isCurrent() else { return nil }
            await notifyBackendMessage(message)
        }
        return page
    }

    private func reportMailSyncError(_ message: String?) {
        if let message {
            if lastMailSyncError != message { backend.errorMessage = message }
        } else if lastMailSyncError != nil && backend.errorMessage == lastMailSyncError {
            backend.errorMessage = nil
        }
        lastMailSyncError = message
    }

    private func updateMailSyncActivity() {
        let states = mailSyncStatuses.values
        let activity: MailSyncActivity
        if states.contains(where: { $0.phase == "importing" }) { activity = .importing(cached: nil) }
        else if states.contains(where: { $0.phase == "syncing" }) { activity = .syncing }
        else if let retry = states.filter({ $0.phase == "retrying" }).compactMap(\.retryAt).min() {
            activity = .waiting(retryAt: retry)
        } else { activity = .idle }
        if mailSyncActivity != activity { mailSyncActivity = activity }
    }

    func searchBackend(account: MailAccount, query: String, loadMore: Bool = false) async {
        guard let sessionID = backend.realtimeGeneration, let identity = account.remote, backend.isAccountConnected(identity.accountID, scope: identity.scope),
              !isSearchingBackend else { return }
        let context = BackendSearchContext(accountID: identity.accountID, scope: identity.scope, query: query)
        if loadMore {
            guard backendSearchContext == context else { return }
        } else {
            backendSearchContext = context
            backendSearchCursor = nil
            backendHasMore = false
        }
        isSearchingBackend = true
        defer { isSearchingBackend = false }
        do {
            let read = store.beginProviderPage(for: identity.localID)
            defer { store.endProviderPage(read) }
            let page: BackendMailPage = try await backend.request("POST", "/v1/mail/accounts/\(identity.accountID.uuidString)/search",
                body: BackendSearchRequest(query: query, limit: 100, cursor: loadMore ? backendSearchCursor : nil))
            let incoming = try await page.localMessages(for: identity)
            func isCurrent() -> Bool {
                backend.realtimeGeneration == sessionID && backendSearchContext == context
                    && backend.isAccountConnected(identity.accountID, scope: identity.scope)
            }
            guard await store.mergeReceivedPage(incoming, read: read, isCurrent: isCurrent),
                  isCurrent() else { return }
            backendSearchCursor = page.nextCursor
            backendHasMore = page.hasMore
            store.lastAction = "Fetched \(page.messages.count) messages from \(identity.email)"
        } catch {
            if backend.realtimeGeneration == sessionID { store.operationError = error.localizedDescription }
        }
    }

    func loadSenderMark(for message: MailMessage) async {
        guard message.currentSenderMark == nil, let id = message.backendMessageID, message.incomingSenderDomain != nil,
              let identity = message.mailAccount.remote, identity.provider == "gmail", let generation = backend.realtimeGeneration,
              backend.isAccountConnected(identity.accountID, scope: identity.scope) else { return }
        let key = "\(identity.localID)/\(id.uuidString)" as NSString
        if let next = absentSenderMarks.object(forKey: key), next.timeIntervalSinceNow > 0 { return }
        do {
            // Rapid keyboard navigation should not start remote verification for every skipped message.
            try await Task.sleep(for: .milliseconds(250))
            let result: BackendSenderMarkResponse = try await backend.request("GET", "/v1/mail/messages/\(id.uuidString)/sender-mark")
            let mark = await result.verifiedSenderMark?.render(for: message, identity: identity)
            guard !Task.isCancelled, backend.realtimeGeneration == generation,
                  backend.isAccountConnected(identity.accountID, scope: identity.scope) else { return }
            if let mark { store.cacheSenderMark(mark, localID: message.id) }
            else { absentSenderMarks.setObject(Date.now.addingTimeInterval(1800) as NSDate, forKey: key) }
        } catch {
            // Optional sender artwork should never interrupt reading or become a persistent failure.
        }
    }

    func fetchProviderMessage(_ id: UUID, for identity: RemoteAccountIdentity) async throws -> MailMessage {
        guard let sessionID = backend.realtimeGeneration,
              backend.isAccountConnected(identity.accountID, scope: identity.scope) else { throw BackendError.notConnected }
        let read = store.beginProviderPage(for: identity.localID)
        defer { store.endProviderPage(read) }
        let row: BackendMailMessage = try await backend.request("GET", "/v1/mail/messages/\(id.uuidString)")
        guard row.id == id, row.accountId == identity.accountID else { throw BackendError.invalidResponse }
        let page = BackendMailPage(messages: [row], nextCursor: nil, hasMore: false)
        let incoming = try await page.localMessages(for: identity)
        func isCurrent() -> Bool {
            backend.realtimeGeneration == sessionID && backend.isAccountConnected(identity.accountID, scope: identity.scope)
        }
        guard await store.mergeReceivedPage(incoming, read: read, isCurrent: isCurrent), isCurrent(),
              let stored = store.messages.first(where: { $0.account == identity.localID && $0.backendMessageID == id })
        else { throw CancellationError() }
        return stored
    }

    func mutateBackendMessage(before: MailMessage, after: MailMessage) async throws {
        guard let identity = after.mailAccount.remote, backend.isAccountConnected(identity.accountID, scope: identity.scope),
              before.account == after.account, before.backendMessageID == after.backendMessageID,
              let id = after.backendMessageID else { throw BackendError.notConnected }
        let _: BackendEmpty = try await backend.request("PATCH", "/v1/mail/messages/\(id.uuidString)", body: BackendMutation(
            isRead: before.isUnread != after.isUnread ? !after.isUnread : nil,
            isStarred: before.isStarred != after.isStarred ? after.isStarred : nil,
            mailbox: before.mailbox != after.mailbox ? after.mailbox.rawValue : nil))
    }

    func resolveBackendAttachment(_ attachment: MailAttachment, in message: MailMessage) async throws -> MailAttachment {
        guard let identity = message.mailAccount.remote, backend.isAccountConnected(identity.accountID, scope: identity.scope),
              let messageID = message.backendMessageID, let attachmentID = attachment.providerAttachmentID, UUID(uuidString: attachmentID) != nil else { throw BackendError.notConnected }
        let data = try await backend.bytes("/v1/mail/messages/\(messageID.uuidString)/attachments/\(attachmentID)")
        guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { throw BackendError.notConnected }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(URL(fileURLWithPath: attachment.name).lastPathComponent)
        try data.write(to: file, options: .atomic)
        let imported = try MailAttachment.importFile(at: file, storageDirectory: store.attachmentStorageDirectory)
        var resolved = attachment
        resolved.localURL = imported.localURL
        if let index = store.messages.firstIndex(where: { $0.id == message.id }),
           let offset = store.messages[index].attachments.firstIndex(where: { $0.id == attachment.id }) {
            store.messages[index].attachments[offset] = resolved
        }
        return resolved
    }
}

nonisolated struct BackendSearchContext: Equatable {
    let accountID: UUID
    let scope: String
    let query: String
}

nonisolated struct BackendMailSyncDemand: OptionSet {
    let rawValue: Int
    static let cache = Self(rawValue: 1)
    static let catalog = Self(rawValue: 2)
    static let provider = Self(rawValue: 4)
}

nonisolated struct BackendSyncInput: Encodable, Sendable { let cursor: String?; let refreshProvider: Bool }

nonisolated struct BackendSearchRequest: Encodable, Sendable {
    let query: String
    let limit: Int
    let cursor: String?
}

nonisolated private struct BackendMutation: Encodable, Sendable {
    let isRead: Bool?
    let isStarred: Bool?
    let mailbox: String?
}
