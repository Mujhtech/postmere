import Foundation
import Observation

/// Labels the user describes in words ("Receipts and invoices"). New mail is
/// read by the workspace's AI in small batches, and the matching provider label
/// (a Gmail label or Outlook category) is applied. Only mail that arrives after
/// a label is described is sorted, and each message is asked about once.
@MainActor
@Observable
final class MailDescribedLabels {
    private(set) var labels: [MailDescribedLabel] = []
    /// Why sorting paused, shown in Settings.
    private(set) var problem: String?
    private(set) var lastSortedCount = 0

    @ObservationIgnored private var scope: String?
    @ObservationIgnored private var processed: [UUID] = []
    @ObservationIgnored private var activeSince: Date = .now
    @ObservationIgnored private var nextRun: Date = .distantPast
    @ObservationIgnored private var running = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct Stored: Codable {
        var labels: [MailDescribedLabel]
        var processed: [UUID]
        var activeSince: Date
    }

    private func key(_ scope: String) -> String { "describedLabels.v1.\(scope)" }

    /// Loads the labels for the signed-in workspace; nil clears them from memory.
    func use(scope: String?) {
        guard scope != self.scope else { return }
        self.scope = scope
        problem = nil
        guard let scope, let data = defaults.data(forKey: key(scope)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            labels = []
            processed = []
            activeSince = .now
            return
        }
        labels = stored.labels
        processed = stored.processed
        activeSince = stored.activeSince
    }

    func save(_ updated: [MailDescribedLabel]) {
        // Sorting starts with mail that arrives from now on, not the whole mailbox.
        if labels.allSatisfy({ !$0.enabled }) && updated.contains(where: \.enabled) { activeSince = .now }
        labels = updated
        problem = nil
        nextRun = .distantPast
        persist()
    }

    private func persist() {
        guard let scope, let data = try? JSONEncoder().encode(Stored(labels: labels, processed: processed, activeSince: activeSince)) else { return }
        defaults.set(data, forKey: key(scope))
    }

    /// Sorts up to 20 new messages; call often, it paces itself.
    func sortNewMail(messages: [MailMessage], store: MailStore, session: BackendSession) async {
        let active = labels.filter { $0.enabled && !$0.labelName.isEmpty && !$0.description.isEmpty }
        guard !active.isEmpty, !running, Date.now >= nextRun, session.canAccessWorkspace, let scope = session.scope,
              scope == self.scope else { return }
        let done = Set(processed)
        let cutoff = max(activeSince, Date.now.addingTimeInterval(-2 * 86_400))
        let candidates = messages
            .filter { message in
                !message.isOutgoing && !message.isDraft && message.sentAt >= cutoff && !done.contains(message.id)
                    && message.backendMessageID != nil && message.mailAccount.remote?.scope == scope
                    && [.inbox, .archive].contains(message.mailbox)
            }
            .sorted { $0.sentAt > $1.sentAt }
            .prefix(20)
        nextRun = Date.now.addingTimeInterval(candidates.isEmpty ? 60 : 20)
        guard !candidates.isEmpty else { return }
        running = true
        defer { running = false }
        let byServerID = Dictionary(candidates.compactMap { message in message.backendMessageID.map { ($0, message) } },
                                    uniquingKeysWith: { first, _ in first })
        do {
            let matches = try await MailAIAssist.classify(Array(byServerID.keys), labels: active, session: session)
            guard session.scope == scope else { return }
            var sorted = 0
            for match in matches where !match.labelIds.isEmpty {
                guard let message = byServerID[match.messageId], let account = message.mailAccount.remote else { continue }
                for labelID in match.labelIds {
                    guard let label = active.first(where: { $0.id == labelID }) else { continue }
                    if try await apply(label.labelName, to: message, account: account, store: store, session: session) { sorted += 1 }
                }
            }
            processed.append(contentsOf: candidates.map(\.id))
            if processed.count > 5_000 { processed.removeFirst(processed.count - 5_000) }
            lastSortedCount += sorted
            problem = nil
            persist()
        } catch BackendError.response(403, _) {
            problem = "Turn on AI to sort mail into these labels."
            nextRun = Date.now.addingTimeInterval(600)
        } catch {
            problem = "Sorting paused: \(error.localizedDescription)"
            nextRun = Date.now.addingTimeInterval(300)
        }
    }

    /// Applies a label by name, creating it in the account the first time.
    private func apply(_ name: String, to message: MailMessage, account: RemoteAccountIdentity,
                       store: MailStore, session: BackendSession) async throws -> Bool {
        guard let serverID = message.backendMessageID else { return false }
        let catalog = try await session.labelCatalog(account: account)
        let label: ProviderLabel
        if let existing = catalog.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            label = existing
        } else {
            label = try await session.createLabel(name: name, account: account)
        }
        guard !message.providerLabelIDs.contains(label.id) else { return false }
        let updated = try await session.setLabel(label.id, applied: true, account: account, messageID: serverID)
        store.applyProviderLabels(updated, messageID: message.id, account: account)
        return true
    }
}
