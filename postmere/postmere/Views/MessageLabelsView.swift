import SwiftUI

struct MessageLabelButton: View {
    @Environment(MailRuntime.self) private var runtime
    let message: MailMessage?
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            PostmereLabel("Label", symbol: "tag", size: 17)
                .labelStyle(.iconOnly)
                .foregroundStyle(PostmereTheme.icon)
        }
        .help("Edit labels or categories for this message")
        .accessibilityLabel("Label message")
        .disabled(message?.mailAccount.isConnected != true)
        .onChange(of: message?.mailAccount.isConnected == true ? message?.id : nil) { presented = false }
        .popover(isPresented: $presented) {
            if let message {
                MessageLabelsView(runtime: runtime, message: message).id(message.id)
            }
        }
    }
}

struct MessageLabelsView: View {
    let runtime: MailRuntime
    let message: MailMessage
    @State private var selection: MessageLabelSelection?
    @State private var search = ""
    @State private var busy = false
    @State private var confirmed = false
    @State private var refreshRevision = 0
    @State private var catalogRevision = 0
    @State private var filtered: LabelMatches?
    @State private var pendingChange: (id: String, applied: Bool)?
    @State private var error: String?
    @State private var needsReconnect = false

    private var outlook: Bool { message.mailAccount.remote?.provider == "microsoft" }
    private var name: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private struct Query: Equatable, Sendable {
        let name: String
        let revision: Int
    }

    private struct LabelMatches: Sendable {
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

    var body: some View {
        let query = Query(name: name, revision: catalogRevision)
        let matches = filtered?.query == query ? filtered : nil
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(outlook ? "Outlook categories" : "Gmail labels").font(.headline)
                Spacer()
                if busy, selection != nil { ProgressView().controlSize(.small).accessibilityLabel("Updating labels") }
            }
            TextField(outlook ? "Find or create a category" : "Find or create a label", text: $search)
                .textFieldStyle(.roundedBorder)
            if let selection {
                let labels = name.isEmpty ? selection.labels : matches?.labels ?? []
                if !labels.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(labels) { label in
                                Toggle(label.name, isOn: Binding(get: {
                                    if let pendingChange, pendingChange.id == label.id { return pendingChange.applied }
                                    return selection.appliedLabelIds.contains(label.id)
                                },
                                    set: { applied in Task { await update(label: label, applied: applied) } }))
                                    .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(2)
                    }
                    .frame(height: min(CGFloat(labels.count) * 26, 232))
                    .disabled(busy || !confirmed)
                } else if name.isEmpty {
                    Text(outlook ? "Enter a name to create your first category." : "Enter a name to create your first label.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let matches, !matches.hasExactName {
                    Button("Create and apply “\(name)”") { Task { await createAndApply() } }
                        .disabled(busy || !confirmed)
                }
            } else if error == nil {
                ProgressView(outlook ? "Loading categories…" : "Loading labels…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if needsReconnect { AccountSettingsButton(title: "Open Accounts Settings…") }
                else { Button("Refresh") { refreshRevision += 1 }.disabled(busy) }
            }
        }
        .padding(16)
        .frame(width: 304)
        .task(id: refreshRevision) { await refresh() }
        .task(id: query) {
            guard !query.name.isEmpty, let selection else { filtered = nil; return }
            let result = try? await LabelMatches.find(query, in: selection.labels)
            if !Task.isCancelled { filtered = result }
        }
    }

    private var destination: (account: RemoteAccountIdentity, id: UUID)? {
        guard let account = message.mailAccount.remote, let id = message.backendMessageID,
              runtime.backend.isAccountConnected(account.accountID, scope: account.scope) else { return nil }
        return (account, id)
    }

    private func refresh() async {
        await perform { account, id in
            if selection == nil, let labels = runtime.backend.cachedLabels(account: account) {
                let preview = await MessageLabelSelection.preview(labels: labels, labelIDs: message.providerLabelIDs,
                    categories: message.providerCategories, outlook: outlook)
                try Task.checkCancellation()
                guard destination?.account.localID == account.localID else { throw BackendError.notConnected }
                selection = preview
                catalogRevision += 1
            }
            let result = try await runtime.backend.labelSelection(account: account, messageID: id)
            try Task.checkCancellation()
            selection = result
            catalogRevision += 1
            confirmed = true
        }
    }

    private func update(label: ProviderLabel, applied: Bool) async {
        await perform { account, id in
            pendingChange = (label.id, applied)
            defer { pendingChange = nil }
            try await setLabel(label, applied: applied, account: account, id: id)
        }
    }

    private func createAndApply() async {
        let requestedName = name
        guard !requestedName.isEmpty else { return }
        await perform { account, id in
            let label: ProviderLabel = try await runtime.backend.createLabel(name: requestedName, account: account)
            if var current = selection {
                current.labels.removeAll { $0.id == label.id }
                current.labels.append(label)
                selection = await current.sortedByName()
                catalogRevision += 1
            }
            try await setLabel(label, applied: true, account: account, id: id)
            if name == requestedName { search = "" }
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
