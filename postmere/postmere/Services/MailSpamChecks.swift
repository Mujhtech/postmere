import Foundation
import Observation

@MainActor @Observable
final class MailSpamChecks {
    enum Phase {
        case checking, result(MailSpamDecision), failed(String)
    }

    private struct Target: Hashable {
        let account: String
        let messageID: UUID
        let generation: UUID
        var cacheKey: String { "\(account)/\(messageID.uuidString)" }

        init?(_ message: MailMessage, session: BackendSession) {
            guard let generation = session.realtimeGeneration, let id = message.backendMessageID,
                  let identity = message.mailAccount.remote,
                  session.isAccountConnected(identity.accountID, scope: identity.scope),
                  !message.isDraft, !message.isFromAccountOwner, !message.isDeletedOnProvider,
                  [.inbox, .archive].contains(message.mailbox) else { return nil }
            account = identity.localID
            messageID = id
            self.generation = generation
        }
    }

    private let store: MailStore
    private let defaults: UserDefaults
    private static let preference = "automaticSpamChecksEnabledSinceByWorkspace"
    private var enabledSince: [String: Date]
    private var foreground: [Target: Phase] = [:]
    @ObservationIgnored private var active: [Target: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var waiting: [Target] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID: UUID?
    @ObservationIgnored private var resumeAutomaticAt = Date.distantPast

    init(store: MailStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        enabledSince = defaults.dictionary(forKey: Self.preference) as? [String: Date] ?? [:]
    }

    static func canCheck(_ message: MailMessage, session: BackendSession) -> Bool {
        Target(message, session: session) != nil
    }

    func phase(for message: MailMessage, session: BackendSession) -> Phase? {
        guard let target = Target(message, session: session) else { return nil }
        if let phase = foreground[target] { return phase }
        guard let saved = store.spamCheckResults[target.cacheKey], saved.isVisible else { return nil }
        return .result(saved.decision)
    }

    func check(_ message: MailMessage, session: BackendSession) {
        guard let target = Target(message, session: session) else { return }
        if var saved = store.spamCheckResults[target.cacheKey] {
            if !saved.isVisible {
                saved.isVisible = true
                store.spamCheckResults[target.cacheKey] = saved
                store.schedulePersistence()
            }
            return
        }
        foreground[target] = .checking
        waiting.removeAll { $0 == target }
        if active[target] == nil { start(target, session: session) }
    }

    func dismiss(_ message: MailMessage, session: BackendSession) {
        guard let target = Target(message, session: session) else { return }
        foreground.removeValue(forKey: target)
        if var saved = store.spamCheckResults[target.cacheKey], saved.isVisible {
            saved.isVisible = false
            store.spamCheckResults[target.cacheKey] = saved
            store.schedulePersistence()
        }
    }

    func automaticChecksEnabled(for session: BackendSession) -> Bool {
        automaticChecksEnabledSince(for: session) != nil
    }

    func automaticChecksEnabledSince(for session: BackendSession) -> Date? {
        session.scope.flatMap { enabledSince[$0] }
    }

    func setAutomaticChecksEnabled(_ enabled: Bool, for session: BackendSession) {
        guard let scope = session.scope, enabled != (enabledSince[scope] != nil) else { return }
        enabledSince[scope] = enabled ? .now : nil
        defaults.set(enabledSince, forKey: Self.preference)
        if !enabled { stopAutomaticChecks() }
    }

    func enqueueIncoming(_ messages: [MailMessage], session: BackendSession) {
        guard let since = automaticChecksEnabledSince(for: session), Date.now >= resumeAutomaticAt else { return }
        for message in messages where message.mailbox == .inbox && message.sentAt >= since {
            guard waiting.count < 64 else { break }
            guard let target = Target(message, session: session), store.spamCheckResults[target.cacheKey] == nil,
                  active[target] == nil, !waiting.contains(target), message.hasSpamCheckSignals else { continue }
            waiting.append(target)
        }
        guard !waiting.isEmpty, worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task {
            defer {
                if workerID == id { worker = nil; workerID = nil }
            }
            while !Task.isCancelled, automaticChecksEnabled(for: session), !waiting.isEmpty {
                let target = waiting.removeFirst()
                guard currentMessage(for: target, session: session)?.mailbox == .inbox,
                      active[target] == nil, store.spamCheckResults[target.cacheKey] == nil else { continue }
                await start(target, session: session).value
                // Space out paid background requests independently of mail sync.
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }

    func cancelPending() {
        stopAutomaticChecks()
        for request in active.values { request.task.cancel() }
        active.removeAll()
        foreground.removeAll()
        resumeAutomaticAt = .distantPast
    }

    private func stopAutomaticChecks() {
        worker?.cancel()
        worker = nil
        workerID = nil
        waiting.removeAll()
        for (target, request) in active where foreground[target] == nil {
            request.task.cancel()
            active.removeValue(forKey: target)
        }
    }

    private func currentMessage(for target: Target, session: BackendSession) -> MailMessage? {
        guard session.realtimeGeneration == target.generation,
              let message = store.messages.first(where: { $0.account == target.account && $0.backendMessageID == target.messageID }),
              Target(message, session: session) == target else { return nil }
        return message
    }

    @discardableResult private func start(_ target: Target, session: BackendSession) -> Task<Void, Never> {
        nonisolated struct Input: Encodable, Sendable { let messageId: UUID }
        let id = UUID()
        let task = Task {
            defer {
                if active[target]?.id == id { active.removeValue(forKey: target) }
            }
            do {
                try Task.checkCancellation()
                guard currentMessage(for: target, session: session) != nil else {
                    foreground.removeValue(forKey: target)
                    return
                }
                let result: MailSpamDecision = try await session.request("POST", "/v1/decisions/spam", body: Input(messageId: target.messageID))
                try Task.checkCancellation()
                guard currentMessage(for: target, session: session) != nil else {
                    foreground.removeValue(forKey: target)
                    return
                }
                guard result.messageId == target.messageID, !result.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BackendAIError.invalidOutput
                }
                let visible = foreground[target] != nil || result.verdict == .possibleSpam
                store.spamCheckResults[target.cacheKey] = StoredSpamCheck(decision: result, isVisible: visible)
                foreground.removeValue(forKey: target)
                store.schedulePersistence()
            } catch {
                guard !Task.isCancelled, session.realtimeGeneration == target.generation else { return }
                if foreground[target] != nil {
                    let message: String
                    if case BackendError.response(403, _) = error {
                        message = "Check that AI assistance is enabled in Settings → General and that this message is accessible."
                    } else {
                        message = error.localizedDescription
                    }
                    foreground[target] = .failed(message)
                }
                // A provider outage, exhausted budget or revoked consent shouldn't drain the queue.
                if case BackendError.response(404, _) = error { return }
                waiting.removeAll()
                resumeAutomaticAt = Date.now.addingTimeInterval(15 * 60)
            }
        }
        active[target] = (id, task)
        return task
    }
}
