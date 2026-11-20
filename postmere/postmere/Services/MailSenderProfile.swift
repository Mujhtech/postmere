import Foundation
import Observation

nonisolated struct SenderProfileTarget: Hashable, Sendable {
    let messageID: UUID
    let accountID: UUID
    let scope: String
    let sessionGeneration: UUID
    let email: String

    @MainActor static func make(message: MailMessage, scope: String?, sessionGeneration: UUID?) -> Self? {
        guard !message.isOutgoing, !message.isDraft, message.mailbox != .outbox, message.providerDeletedAt == nil,
              let messageID = message.backendMessageID, let account = message.mailAccount.remote,
              account.status == "connected", let scope, account.scope == scope, let sessionGeneration else { return nil }
        let email = message.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let address = MailAddressList(email)
        guard email.count <= 320, address.invalid.isEmpty, address.addresses.count == 1,
              address.addresses.first?.caseInsensitiveCompare(email) == .orderedSame else { return nil }
        return Self(messageID: messageID, accountID: account.accountID, scope: scope, sessionGeneration: sessionGeneration, email: email)
    }
}

/// Only the active view result lives in memory. Reselection asks the server
/// again so its scoped cache can recheck consent and account authorization.
@MainActor @Observable final class MailSenderProfile {
    enum Phase {
        case idle, loading
        case loaded(BackendSenderProfileResponse)
        case failed(String)
    }
    private(set) var phase: Phase = .idle
    private(set) var target: SenderProfileTarget?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    func cancel() {
        generation = UUID()
        requestTask?.cancel(); requestTask = nil
        target = nil; phase = .idle
    }

    func load(target: SenderProfileTarget, refresh: Bool = false,
              isCurrent: @escaping @MainActor () -> Bool = { true },
              fetch: @escaping @MainActor (UUID, SenderProfileRequest) async throws -> BackendSenderProfileResponse) async {
        guard !Task.isCancelled, isCurrent() else { return }
        cancel()
        self.target = target
        let requestGeneration = generation
        phase = .loading
        let task = Task { [weak self] in
            guard !Task.isCancelled, isCurrent() else {
                if self?.generation == requestGeneration { self?.phase = .idle }
                return
            }
            do {
                let response = try await fetch(target.messageID, SenderProfileRequest(refresh: refresh)).validated(for: target.email)
                guard let self, self.generation == requestGeneration else { return }
                guard !Task.isCancelled, isCurrent() else { self.phase = .idle; return }
                self.phase = .loaded(response)
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                guard !Task.isCancelled, isCurrent() else { self.phase = .idle; return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { self.phase = .idle }
                else { self.phase = .failed(error.localizedDescription) }
            }
        }
        requestTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == requestGeneration { requestTask = nil }
    }
}
