import Foundation
import Observation

/// Loads, filters, applies and creates provider labels (Gmail labels or Outlook
/// categories) for one message. The Mac popover and the phone sheet share it.
@MainActor @Observable
final class MessageLabelEditor {
    let runtime: MailRuntime
    let message: MailMessage

    var search = "" { didSet { if search != oldValue { scheduleFilter() } } }
    private(set) var selection: MessageLabelSelection?
    private(set) var busy = false
    private(set) var confirmed = false
    private(set) var filtered: LabelMatches?
    private(set) var pendingChange: (id: String, applied: Bool)?
    private(set) var error: String?
    private(set) var needsReconnect = false
    private var catalogRevision = 0
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    init(runtime: MailRuntime, message: MailMessage) {
        self.runtime = runtime
        self.message = message
    }

    var outlook: Bool { message.mailAccount.remote?.provider == "microsoft" }
    var name: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var query: Query { Query(name: name, revision: catalogRevision) }

    struct Query: Equatable, Sendable {
        let name: String
        let revision: Int
    }

    struct LabelMatches: Sendable {
        let query: Query
        let labels: [ProviderLabel]
        let hasExactName: Bool

        @concurrent static func find(_ query: Query, in catalog: [ProviderLabel]) async throws -> Self {
            var labels: [ProviderLabel] = []
            var hasExactName = false
            for label in catalog {
                try Task.checkCancellation()
                if label.name.localizedCaseInsensitiveContains(query.name) {
                    labels.append(label)
                    if label.name.caseInsensitiveCompare(query.name) == .orderedSame { hasExactName = true }
                }
            }
            return Self(query: query, labels: labels, hasExactName: hasExactName)
        }
    }

    /// The labels to list: everything, or the matches for the current search.
    var visibleLabels: [ProviderLabel] {
        guard let selection else { return [] }
        if name.isEmpty { return selection.labels }
        return currentMatches?.labels ?? []
    }

    /// Offers "Create and apply" once the search has no exact match.
    var canCreate: Bool {
        guard let matches = currentMatches else { return false }
        return !matches.hasExactName
    }

    private var currentMatches: LabelMatches? { filtered?.query == query ? filtered : nil }

    func isApplied(_ label: ProviderLabel) -> Bool {
        if let pendingChange, pendingChange.id == label.id { return pendingChange.applied }
        return selection?.appliedLabelIds.contains(label.id) == true
    }

    private var destination: (account: RemoteAccountIdentity, id: UUID)? {
        guard let account = message.mailAccount.remote, let id = message.backendMessageID,
              runtime.backend.isAccountConnected(account.accountID, scope: account.scope) else { return nil }
        return (account, id)
    }

    func refresh() async {
        await perform { account, id in
            if self.selection == nil, let labels = self.runtime.backend.cachedLabels(account: account) {
                let preview = await MessageLabelSelection.preview(labels: labels, labelIDs: self.message.providerLabelIDs,
                    categories: self.message.providerCategories, outlook: self.outlook)
                try Task.checkCancellation()
                guard self.destination?.account.localID == account.localID else { throw BackendError.notConnected }
                self.selection = preview
                self.catalogChanged()
            }
            let result = try await self.runtime.backend.labelSelection(account: account, messageID: id)
            try Task.checkCancellation()
            self.selection = result
            self.catalogChanged()
            self.confirmed = true
        }
    }

    func update(label: ProviderLabel, applied: Bool) async {
        await perform { account, id in
            self.pendingChange = (label.id, applied)
            defer { self.pendingChange = nil }
            try await self.setLabel(label, applied: applied, account: account, id: id)
        }
    }

    func createAndApply() async {
        let requestedName = name
        guard !requestedName.isEmpty else { return }
        await perform { account, id in
            let label: ProviderLabel = try await self.runtime.backend.createLabel(name: requestedName, account: account)
            // The sidebar lists the new label straight away.
            if self.runtime.store.labelCatalogs[account.localID]?.contains(where: { $0.id == label.id }) == false {
                self.runtime.store.labelCatalogs[account.localID]?.append(label)
            }
            if var current = self.selection {
                current.labels.removeAll { $0.id == label.id }
                current.labels.append(label)
                self.selection = await current.sortedByName()
                self.catalogChanged()
            }
            try await self.setLabel(label, applied: true, account: account, id: id)
            if self.name == requestedName { self.search = "" }
        }
    }

    private func setLabel(_ label: ProviderLabel, applied: Bool, account: RemoteAccountIdentity, id: UUID) async throws {
        guard destination?.account.localID == account.localID else { throw BackendError.notConnected }
        let updated = try await runtime.backend.setLabel(label.id, applied: applied, account: account, messageID: id)
        runtime.store.applyProviderLabels(updated, messageID: message.id, account: account)
        if let labels = selection?.labels {
            selection = await MessageLabelSelection.preview(labels: labels, labelIDs: updated.providerLabels,
                categories: updated.categories, outlook: outlook)
        }
    }

    private func catalogChanged() {
        catalogRevision += 1
        scheduleFilter()
    }

    private func scheduleFilter() {
        filterTask?.cancel()
        let query = query
        guard !query.name.isEmpty, let labels = selection?.labels else { filtered = nil; return }
        filterTask = Task {
            let result = try? await LabelMatches.find(query, in: labels)
            if !Task.isCancelled { filtered = result }
        }
    }

    private func perform(_ work: (RemoteAccountIdentity, UUID) async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        needsReconnect = false
        do {
            guard let target = destination else { throw BackendError.notConnected }
            try await work(target.account, target.id)
        } catch BackendError.response(412, _) {
            selection = nil
            confirmed = false
            error = "Reconnect this account to give Postmere access to its \(outlook ? "categories" : "labels")."
            needsReconnect = true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
