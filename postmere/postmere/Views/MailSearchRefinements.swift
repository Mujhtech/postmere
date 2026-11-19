import SwiftUI

struct MailSearchRefinements: View {
    @Bindable var store: MailStore
    let canSearchOnline: Bool
    let onSaveView: () -> Void
    let onSearchOnline: () -> Void

    @State private var showsSender = false
    @State private var optionsPanel: OptionsPanel?

    private enum OptionsPanel: String, Identifiable {
        case conditions, help
        var id: Self { self }
    }

    var body: some View {
        let query = store.parsedSearchQuery
        let required = query.requiredFilterTokens
        let sender = required.last { $0.field == "from" }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        Button { showsSender = true } label: {
                            chip(sender.map { "From \($0.value)" } ?? "From…", selected: sender != nil)
                        }
                        .help("Filter by sender")
                        .popover(isPresented: $showsSender) {
                            SearchSenderPicker(store: store, initialValue: sender?.value ?? "", onApply: { value in
                                let condition = MailSearchQuery.senderCondition(value)
                                let current = store.parsedSearchQuery
                                if let token = current.requiredFilterTokens.last(where: { $0.field == "from" }) {
                                    store.updateSearchText(current.replacingToken(id: token.id, with: condition))
                                } else {
                                    store.updateSearchText(current.addingRequiredFilter(condition))
                                }
                                showsSender = false
                            }, onRemove: sender.map { token in
                                {
                                    store.updateSearchText(store.parsedSearchQuery.removingRequiredFilter(token))
                                    showsSender = false
                                }
                            })
                        }
                        filterButton("With attachments", condition: "has:attachment", query: query,
                                     token: required.last { $0.field == "has" && ["attachment", "attachments"].contains($0.value.lowercased()) })
                        filterButton("Unread", condition: "is:unread", query: query,
                                     token: required.last { $0.field == "is" && $0.value.lowercased() == "unread" })
                        filterButton("This week", condition: "date:this-week", query: query,
                                     token: required.last { $0.field == "date" && $0.value.lowercased() == "this-week" })
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .disabled(!query.isValid)
                }
                .scrollIndicators(.never)
                optionsMenu
            }
            ForEach(query.issues.prefix(2)) { issue in
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func filterButton(_ title: String, condition: String, query: MailSearchQuery, token: MailSearchToken?) -> some View {
        let selected = token != nil
        return Button {
            store.updateSearchText(token.map { query.removingRequiredFilter($0) } ?? query.addingRequiredFilter(condition))
        } label: {
            chip(title, symbol: selected ? "checkmark" : "plus", selected: selected)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(selected ? "Remove the \(title.lowercased()) filter" : "Filter results by \(title.lowercased())")
    }

    private func chip(_ title: String, symbol: String? = nil, selected: Bool) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .medium)).accessibilityHidden(true) }
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: 150)
        .fixedSize(horizontal: true, vertical: false)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(selected ? PostmereTheme.accentInk : Color.secondary)
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background(selected ? PostmereTheme.accentInk.opacity(0.10) : Color.clear, in: .rect(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? PostmereTheme.accentInk.opacity(0.35) : PostmereTheme.rule) }
        .contentShape(Rectangle())
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Search scope", selection: $store.searchScope) {
                ForEach(MailSearchScope.allCases) { scope in Text(scope.title).tag(scope) }
            }
            .pickerStyle(.menu)
            Picker("Search field", selection: $store.searchField) {
                ForEach(MailSearchField.allCases) { field in Text(field.title).tag(field) }
            }
            .pickerStyle(.menu)
            if !store.searchTokens.isEmpty {
                Button("Edit Search Conditions…") { optionsPanel = .conditions }
            }
            Divider()
            Button("Save Search as View…", action: onSaveView)
                .disabled(!store.hasSearchCriteria)
            if canSearchOnline { Button("Search Online…", action: onSearchOnline) }
            Button("Search Tips…") { optionsPanel = .help }
            Divider()
            Button("Done Searching", action: store.endSearch)
        } label: {
            PostmereIcon("ellipsis.circle", size: 15)
                .foregroundStyle(PostmereTheme.icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Search options")
        .help("Search options")
        .popover(item: $optionsPanel) { panel in
            switch panel {
            case .conditions:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Search conditions").font(.headline)
                    MailSearchTokenControls(store: store)
                }
                .padding(16)
                .frame(width: 330)
            case .help:
                MailSearchHelp { store.updateSearchText($0) }
            }
        }
    }
}

private struct SearchSenderPicker: View {
    let store: MailStore
    let onApply: (String) -> Void
    let onRemove: (() -> Void)?
    @State private var input: String
    @FocusState private var focused: Bool

    init(store: MailStore, initialValue: String, onApply: @escaping (String) -> Void, onRemove: (() -> Void)?) {
        self.store = store
        self.onApply = onApply
        self.onRemove = onRemove
        _input = State(initialValue: initialValue)
    }

    private var value: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var suggestions: [MailMessage] {
        var seen = Set<String>()
        var matches: [MailMessage] = []
        let term = value
        for message in store.messages {
            let email = message.senderEmail
            guard !email.isEmpty, store.isAccountVisible(message),
                  store.selectedAccount == nil || message.account == store.selectedAccount,
                  store.searchScope == .allMailboxes || store.matchesMailbox(message, mailbox: store.selectedMailbox),
                  term.isEmpty || email.localizedStandardContains(term) || message.sender.localizedStandardContains(term),
                  seen.insert(email.lowercased()).inserted else { continue }
            matches.append(message)
            if matches.count == 5 { break }
        }
        return matches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From").font(.headline)
            TextField("Name or email address", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !value.isEmpty { onApply(value) } }
            ForEach(suggestions) { message in
                Button { onApply(message.senderEmail) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if !message.sender.isEmpty && message.sender != message.senderEmail {
                            Text(message.sender).font(.callout).lineLimit(1)
                        }
                        Text(message.senderEmail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                if let onRemove { Button("Remove Filter", action: onRemove) }
                Spacer()
                Button("Apply") { onApply(value) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 265)
        .onAppear { focused = true }
    }
}
