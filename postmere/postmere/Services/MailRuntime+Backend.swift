import Foundation

extension MailRuntime {
    func syncBackend(refreshProvider: Bool = true) async {
        guard let sessionID = backend.realtimeGeneration, let requestScope = backend.scope, !isSyncingBackend else { return }
        isSyncingBackend = true
        if refreshProvider {
            lastBackendSync = .now
            lastBackendSyncScope = requestScope
        }
        defer { isSyncingBackend = false }
        do {
            try await backend.refreshAccounts()
            guard backend.realtimeGeneration == sessionID else { return }
            // Restore remote-delivery ownership before new cache rows can
            // schedule a duplicate local alert after a quit/relaunch.
            await synchronizePush()
            guard backend.realtimeGeneration == sessionID else { return }
            let identities = RemoteAccountRegistry.accounts.filter { $0.scope == requestScope }
            var failures: [String] = []
            for identity in identities {
                guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { continue }
                guard await store.prepareBackendNotifications(for: identity) else { return }
                do {
                    for _ in 0..<5 {
                        try Task.checkCancellation()
                        guard backend.realtimeGeneration == sessionID, backend.isAccountConnected(identity.accountID, scope: identity.scope) else { break }
                        let cursor = store.backendSyncCursors[identity.localID]
                        let known = Set(store.messages.filter { $0.account == identity.localID }.map(\.id))
                        let read = store.beginProviderPage(for: identity.localID)
                        defer { store.endProviderPage(read) }
                        let page: BackendMailPage
                        do {
                            page = try await backend.request("POST", "/v1/mail/accounts/\(identity.accountID.uuidString)/sync", body: BackendSyncInput(cursor: cursor, refreshProvider: refreshProvider ? nil : false))
                        } catch BackendError.response(400, _) where cursor != nil {
                            guard backend.realtimeGeneration == sessionID, backend.isAccountConnected(identity.accountID, scope: identity.scope) else { break }
                            // A retired cursor key or reset server cache requires a
                            // complete replay. Retain all local messages meanwhile.
                            store.backendSyncCursors[identity.localID] = nil
                            guard await store.persistStateAsync() else { return }
                            continue
                        }
                        guard backend.realtimeGeneration == sessionID else { return }
                        guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { break }
                        guard await store.applyBackendPage(page, identity: identity, read: read, isCurrent: {
                            self.backend.realtimeGeneration == sessionID && self.backend.isAccountConnected(identity.accountID, scope: requestScope)
                        }) else { return }
                        guard backend.realtimeGeneration == sessionID else { return }
                        guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { break }
                        for message in store.backendNotificationCandidates(for: identity, excluding: known) {
                            await notifyBackendMessage(message)
                        }
                        if !page.hasMore { break }
                    }
                } catch {
                    guard backend.realtimeGeneration == sessionID else { return }
                    if backend.isAccountConnected(identity.accountID, scope: identity.scope) {
                        failures.append("\(identity.email): \(error.localizedDescription)")
                    }
                }
                guard backend.realtimeGeneration == sessionID else { return }
            }
            store.reconcileSelection()
            backend.errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        } catch {
            if backend.realtimeGeneration == sessionID { backend.errorMessage = error.localizedDescription }
        }
    }

    func searchBackend(account: MailAccount, query: String, loadMore: Bool = false) async {
        guard let sessionID = backend.realtimeGeneration, let identity = account.remote, backend.isAccountConnected(identity.accountID, scope: identity.scope),
              !isSyncingBackend else { return }
        let context = BackendSearchContext(accountID: identity.accountID, scope: identity.scope, query: query)
        if loadMore {
            guard backendSearchContext == context else { return }
        } else {
            backendSearchContext = context
            backendSearchCursor = nil
            backendHasMore = false
        }
        isSyncingBackend = true
        defer { isSyncingBackend = false }
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

nonisolated struct BackendSyncInput: Encodable, Sendable { let cursor: String?; var refreshProvider: Bool? = nil }

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
