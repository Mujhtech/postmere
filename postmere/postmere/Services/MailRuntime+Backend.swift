import Foundation

extension MailRuntime {
    func syncBackend() async {
        guard let requestScope = backend.scope, !isSyncingBackend else { return }
        isSyncingBackend = true
        lastBackendSync = .now
        lastBackendSyncScope = requestScope
        defer { isSyncingBackend = false }
        do {
            try await backend.refreshAccounts()
            guard backend.scope == requestScope else { return }
            let identities = RemoteAccountRegistry.accounts.filter { $0.scope == requestScope }
            var failures: [String] = []
            for identity in identities {
                guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { continue }
                guard store.prepareBackendNotifications(for: identity) else { return }
                do {
                    for _ in 0..<5 {
                        try Task.checkCancellation()
                        guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { break }
                        let cursor = store.backendSyncCursors[identity.localID]
                        let known = Set(store.messages.filter { $0.account == identity.localID }.map(\.id))
                        let page: BackendMailPage
                        do {
                            page = try await backend.request("POST", "/v1/mail/accounts/\(identity.accountID.uuidString)/sync", body: BackendSyncInput(cursor: cursor))
                        } catch BackendError.response(400, _) where cursor != nil {
                            guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { break }
                            // A retired cursor key or reset server cache requires a
                            // complete replay. Retain all local messages meanwhile.
                            store.backendSyncCursors[identity.localID] = nil
                            guard store.persistState() else { return }
                            continue
                        }
                        guard backend.scope == requestScope else { return }
                        guard backend.isAccountConnected(identity.accountID, scope: identity.scope) else { break }
                        guard store.applyBackendPage(page, identity: identity) else { return }
                        for message in store.backendNotificationCandidates(for: identity, excluding: known) {
                            await notifications.notifyNewMessage(message)
                        }
                        if !page.hasMore { break }
                    }
                } catch {
                    guard backend.scope == requestScope else { return }
                    if backend.isAccountConnected(identity.accountID, scope: identity.scope) {
                        failures.append("\(identity.email): \(error.localizedDescription)")
                    }
                }
                guard backend.scope == requestScope else { return }
            }
            store.reconcileSelection()
            backend.errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        } catch {
            if backend.scope == requestScope { backend.errorMessage = error.localizedDescription }
        }
    }

    func searchBackend(account: MailAccount, query: String, loadMore: Bool = false) async {
        guard let identity = account.remote, backend.isAccountConnected(identity.accountID, scope: identity.scope),
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
            let page: BackendMailPage = try await backend.request("POST", "/v1/mail/accounts/\(identity.accountID.uuidString)/search",
                body: BackendSearchRequest(query: query, limit: 100, cursor: loadMore ? backendSearchCursor : nil))
            guard backend.isAccountConnected(identity.accountID, scope: identity.scope), backendSearchContext == context else { return }
            store.mergeIncoming(page.messages.filter { $0.accountId == identity.accountID }.map { $0.localMessage(identity: identity) })
            backendSearchCursor = page.nextCursor
            backendHasMore = page.hasMore
            store.lastAction = "Fetched \(page.messages.count) messages from \(identity.email)"
        } catch {
            if backend.scope == identity.scope { store.operationError = error.localizedDescription }
        }
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

nonisolated struct BackendSyncInput: Encodable, Sendable { let cursor: String? }

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
