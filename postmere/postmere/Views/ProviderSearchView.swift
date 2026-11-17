import SwiftUI

struct ProviderSearchView: View {
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: UUID?
    @State private var query = ""
    @State private var messages: [MailMessage] = []
    @State private var cursor: String?
    @State private var hasMore = false
    @State private var busy = false
    @State private var error: String?
    @State private var searchedQuery = ""
    @State private var didSearch = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search all mail").font(PostmereTheme.sheetTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Account", selection: $accountID) {
                    Text("Choose account").tag(Optional<UUID>.none)
                    ForEach(runtime.backend.accounts) { Text($0.email).tag(Optional($0.id)) }
                }
                HStack {
                    TextField("Search your provider’s full mailbox", text: $query).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await search(loadMore: false) } }
                    Button("Search") { Task { await search(loadMore: false) } }
                        .buttonStyle(.borderedProminent).disabled(busy || accountID == nil)
                }
                Text("Uses your provider’s search syntax. Results can include older messages that are not yet saved on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(.horizontal, 22).padding(.bottom, 18)
            Divider()
            if busy && messages.isEmpty { ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if messages.isEmpty {
                ContentUnavailableView {
                    PostmereLabel(didSearch ? "No results" : "Find older mail", symbol: "magnifyingglass", size: 34)
                } description: { Text(didSearch ? "Try another query." : "Choose an account and enter a search.") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(messages) { message in
                        Button {
                            runtime.store.selectAccount(message.account)
                            runtime.store.selectedInboxSplitID = nil
                            runtime.store.selectedMailbox = message.mailbox
                            runtime.store.select(message)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(message.sender).font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(message.sentAt, format: .dateTime.month(.abbreviated).day().year()).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(message.subject).lineLimit(1)
                                Text(message.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.scrollIndicators(.never)
            }
            if hasMore {
                Button(busy ? "Loading…" : "Load older results") { Task { await search(loadMore: true) } }
                    .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines) != searchedQuery).padding(14)
            }
        }.frame(width: 620, height: 610).tint(PostmereTheme.accent)
            .onAppear { accountID = runtime.store.selectedAccount.flatMap { MailAccount(rawValue: $0) }?.remote?.accountID ?? runtime.backend.accounts.first?.id }
            .onChange(of: accountID) { messages = []; cursor = nil; hasMore = false; searchedQuery = ""; didSearch = false }
    }

    private func search(loadMore: Bool) async {
        guard !busy, let accountID, let identity = RemoteAccountRegistry.accounts.first(where: { $0.accountID == accountID }) else { return }
        busy = true
        error = nil
        defer { busy = false }
        let captured = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let page: BackendMailPage = try await runtime.backend.request("POST", "/v1/mail/accounts/\(accountID.uuidString)/search",
                body: BackendSearchRequest(query: captured, limit: 50, cursor: loadMore ? cursor : nil))
            guard self.accountID == accountID, runtime.backend.scope == identity.scope else { return }
            let incoming = page.messages.filter { $0.accountId == accountID }.map { $0.localMessage(identity: identity) }
            runtime.store.mergeIncoming(incoming)
            if loadMore {
                let known = Set(messages.map(\.id))
                messages.append(contentsOf: incoming.filter { !known.contains($0.id) })
            } else { messages = incoming }
            cursor = page.nextCursor
            hasMore = page.hasMore
            searchedQuery = captured
            didSearch = true
        } catch { self.error = error.localizedDescription }
    }
}
