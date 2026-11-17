import AppKit
import Foundation

nonisolated struct BackendOutboxItem: Decodable, Sendable, Identifiable {
    let id: UUID
    let clientId: UUID
    let accountId: UUID
    let status: String
    let scheduledAt: Date
    let undoUntil: Date
    let providerMessageId: String?
    let errorCode: String?
    let createdAt: Date
}
nonisolated private struct BackendOutboxList: Decodable, Sendable { let items: [BackendOutboxItem] }
nonisolated private struct BackendSendAttachment: Encodable, Sendable {
    let filename: String
    let mimeType: String
    let dataBase64: String
}
nonisolated private struct BackendSendRequest: Encodable, Sendable {
    let clientId: UUID
    let accountId: UUID
    let to: [BackendAddress]
    let cc: [BackendAddress]
    let bcc: [BackendAddress]
    let subject: String
    let textBody: String
    let htmlBody: String?
    let attachments: [BackendSendAttachment]
    let scheduledAt: Date
    let undoSeconds: Int
    let trackOpens: Bool
    let trackLinks: Bool
    let inReplyTo: String?
    let references: [String]
    let providerThreadId: String?
}

extension MailRuntime {
    func processBackendOutbox() async {
        guard backend.isConnected, !isProcessingBackendOutbox else { return }
        isProcessingBackendOutbox = true
        defer { isProcessingBackendOutbox = false }
        let pending = store.outgoingQueue.filter { $0.status == .pending && $0.serverJobID == nil }.map(\.id)
        for id in pending {
            guard let message = store.messages.first(where: { $0.id == id }),
                  message.mailAccount.remote?.scope == backend.scope else { continue }
            do {
                let job = try await submitBackendSend(id)
                applyBackendJob(job)
                if store.outgoingQueue.first(where: { $0.id == id })?.cancellationRequested == true { await cancelBackendSend(id) }
            } catch {
                if let index = store.outgoingQueue.firstIndex(where: { $0.id == id }) {
                    store.outgoingQueue[index].status = .failed
                    store.outgoingQueue[index].lastError = "Could not confirm server acceptance. Retry safely with the same request ID. \(error.localizedDescription)"
                }
            }
        }
        guard Date.now.timeIntervalSince(lastBackendOutboxRefresh) >= 5,
              store.outgoingQueue.contains(where: { $0.serverJobID != nil }) else { return }
        lastBackendOutboxRefresh = .now
        do {
            let response: BackendOutboxList = try await backend.request("GET", "/v1/mail/outbox")
            for job in response.items { applyBackendJob(job) }
        } catch { backend.errorMessage = error.localizedDescription }
    }

    private func submitBackendSend(_ id: UUID) async throws -> BackendOutboxItem {
        guard let message = store.messages.first(where: { $0.id == id }),
              let identity = message.mailAccount.remote, identity.scope == backend.scope,
              let index = store.outgoingQueue.firstIndex(where: { $0.id == id }),
              !submittingBackendItems.contains(id) else { throw BackendError.notConnected }
        let item = store.outgoingQueue[index]
        // Also migrates a queued item created before deterministic remote
        // Message-IDs were assigned at queue time.
        if let messageIndex = store.messages.firstIndex(where: { $0.id == id }) {
            store.messages[messageIndex].rfcMessageID = "<\(id.uuidString.lowercased())@postmere.local>"
        }
        // Persist before the first network suspension. A restart/cancel repeats
        // this same idempotent request, never inventing another delivery ID.
        store.outgoingQueue[index].submissionStarted = true
        guard store.persistState() else { throw MailStorageError.missingSender }
        submittingBackendItems.insert(id)
        defer { submittingBackendItems.remove(id) }
        var remainingBytes = 20 * 1024 * 1024
        let attachments = try message.attachments.map { attachment -> BackendSendAttachment in
            guard let url = attachment.localURL else { throw BackendError.response(400, "Download all attachments before sending.") }
            let bytes = try MailAttachment.boundedFileData(at: url, maximumBytes: min(15 * 1024 * 1024, remainingBytes))
            remainingBytes -= bytes.count
            return BackendSendAttachment(filename: attachment.name, mimeType: attachment.mimeType ?? "application/octet-stream", dataBase64: bytes.base64EncodedString())
        }
        let html: String?
        if let rtf = message.bodyRTF,
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
            html = String(data: data, encoding: .utf8)
        } else { html = nil }
        let body = BackendSendRequest(clientId: id, accountId: identity.accountID,
            to: message.toRecipients.map { BackendAddress(email: $0) }, cc: message.ccRecipients.map { BackendAddress(email: $0) },
            bcc: message.bccRecipients.map { BackendAddress(email: $0) }, subject: message.subject,
            textBody: message.paragraphs.joined(separator: "\n\n"), htmlBody: html, attachments: attachments,
            scheduledAt: item.scheduledAt, undoSeconds: max(5, min(60, Int(item.undoUntil.timeIntervalSince(item.queuedAt)))),
            trackOpens: message.trackOpens ?? false, trackLinks: message.trackLinks ?? false,
            inReplyTo: message.inReplyTo, references: message.references, providerThreadId: message.providerThreadID)
        return try await backend.request("POST", "/v1/mail/outbox", body: body)
    }

    func cancelBackendSend(_ id: UUID) async {
        guard let index = store.outgoingQueue.firstIndex(where: { $0.id == id }),
              let message = store.messages.first(where: { $0.id == id }), message.mailAccount.remote?.scope == backend.scope else {
            store.operationError = BackendError.notConnected.localizedDescription; return
        }
        store.outgoingQueue[index].cancellationRequested = true
        guard store.persistState() else { return }
        if submittingBackendItems.contains(id) { store.lastAction = "Cancelling after the server confirms receipt…"; return }
        let item = store.outgoingQueue[index]
        if item.serverJobID == nil && item.submissionStarted != true { store.restoreQueuedDraft(id); return }
        do {
            let jobID: UUID
            if let known = item.serverJobID { jobID = known }
            else {
                let job = try await submitBackendSend(id)
                applyBackendJob(job)
                jobID = job.id
            }
            let job: BackendOutboxItem = try await backend.request("POST", "/v1/mail/outbox/\(jobID.uuidString)/cancel", body: BackendEmpty())
            applyBackendJob(job)
        } catch { store.operationError = "Cancellation was not confirmed. The message may still be delivered. \(error.localizedDescription)" }
    }

    func retryBackendSend(_ id: UUID) async {
        guard let index = store.outgoingQueue.firstIndex(where: { $0.id == id }),
              let message = store.messages.first(where: { $0.id == id }), message.mailAccount.remote?.scope == backend.scope else {
            store.operationError = BackendError.notConnected.localizedDescription; return
        }
        let item = store.outgoingQueue[index]
        guard item.serverState != "uncertain" else {
            store.operationError = "The provider may have accepted this message. Check Sent before composing another copy."; return
        }
        do {
            let job: BackendOutboxItem
            if let serverID = item.serverJobID {
                job = try await backend.request("POST", "/v1/mail/outbox/\(serverID.uuidString)/retry", body: BackendEmpty())
            } else { job = try await submitBackendSend(id) }
            applyBackendJob(job)
        } catch { store.operationError = error.localizedDescription }
    }

    private func applyBackendJob(_ job: BackendOutboxItem) {
        guard let queueIndex = store.outgoingQueue.firstIndex(where: { $0.id == job.clientId }),
              let messageIndex = store.messages.firstIndex(where: { $0.id == job.clientId }),
              let identity = store.messages[messageIndex].mailAccount.remote,
              identity.scope == backend.scope, identity.accountID == job.accountId else { return }
        store.persistenceSuspended += 1
        store.suppressRemoteMutations = true
        defer {
            store.suppressRemoteMutations = false
            store.persistenceSuspended -= 1
            store.persistState()
            store.reconcileSelection()
        }
        store.outgoingQueue[queueIndex].serverJobID = job.id
        store.outgoingQueue[queueIndex].serverState = job.status
        store.outgoingQueue[queueIndex].scheduledAt = job.scheduledAt
        store.outgoingQueue[queueIndex].undoUntil = job.undoUntil
        store.messages[messageIndex].backendOutboxID = job.id
        switch job.status {
        case "pending":
            store.outgoingQueue[queueIndex].status = .pending
            store.outgoingQueue[queueIndex].lastError = nil
            store.lastAction = "Accepted by server · delivery continues while Postmere is closed"
        case "delivering": store.outgoingQueue[queueIndex].status = .delivering
        case "sent":
            store.messages[messageIndex].mailbox = .sent
            if let receipt = job.providerMessageId { store.messages[messageIndex].providerMessageID = receipt }
            store.messages[messageIndex].sentAt = .now
            store.messages[messageIndex].workflow.scheduledSendAt = nil
            store.messages[messageIndex].workflow.needsReply = false
            if store.messages[messageIndex].workflow.followUpAt != nil { store.messages[messageIndex].workflow.followUpReferenceDate = .now }
            store.outgoingQueue.remove(at: queueIndex)
            store.lastAction = "Message sent"
        case "cancelled":
            store.messages[messageIndex].backendOutboxID = nil
            store.restoreQueuedDraft(job.clientId)
        case "uncertain":
            store.outgoingQueue[queueIndex].status = .failed
            store.outgoingQueue[queueIndex].lastError = "Delivery could not be confirmed. Check Sent; automatic retry is disabled to avoid duplicates."
        case "failed":
            store.outgoingQueue[queueIndex].status = .failed
            store.outgoingQueue[queueIndex].lastError = "The server could not send this message. Check the account connection before retrying."
        default: break
        }
    }
}
