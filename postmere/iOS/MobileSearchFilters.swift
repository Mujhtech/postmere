import SwiftUI

/// The Mac's search refinements: From, attachments, unread, this week, no Trash or Junk,
/// plus where and what to search. Each chip edits the search text itself, so typed and
/// tapped conditions stay in step.
struct MobileSearchFilters: View {
    @Bindable var store: MailStore
    let onSaveView: () -> Void
    let onSearchOnline: (() -> Void)?
    @Environment(\.postmereAccent) private var palette
    @State private var picksSender = false
    @State private var showsTips = false

    var body: some View {
        let query = store.parsedSearchQuery
        let required = query.requiredFilterTokens
        let sender = required.last { $0.field == "from" }
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        options
                        chip(sender.map { "From \($0.value)" } ?? "From…", symbol: "person", selected: sender != nil) {
                            picksSender = true
                        }
                        filter("Attachments", symbol: "paperclip", condition: "has:attachment", query: query,
                               token: required.last { $0.field == "has" && ["attachment", "attachments"].contains($0.value.lowercased()) })
                        filter("Unread", symbol: "circle.fill", condition: "is:unread", query: query,
                               token: required.last { $0.field == "is" && $0.value.lowercased() == "unread" })
                        filter("This week", symbol: "calendar", condition: "date:this-week", query: query,
                               token: required.last { $0.field == "date" && $0.value.lowercased() == "this-week" })
                        trashFilter(query)
                        if store.hasSearchCriteria {
                            chip("Save as View", symbol: "plus", selected: false, action: onSaveView)
                        }
                    }
                    .disabled(!query.isValid)
                }
                .padding(.horizontal, Mobile.gutter)
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            ForEach(query.issues.prefix(2)) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(PostmereTheme.destructiveInk)
                    .padding(.horizontal, Mobile.gutter)
            }
        }
        .sheet(isPresented: $picksSender) {
            MobileSenderFilterSheet(store: store, initial: sender?.value ?? "", canRemove: sender != nil) { value in
                let current = store.parsedSearchQuery
                if let value {
                    let condition = MailSearchQuery.senderCondition(value)
                    if let token = current.requiredFilterTokens.last(where: { $0.field == "from" }) {
                        store.updateSearchText(current.replacingToken(id: token.id, with: condition))
                    } else {
                        store.updateSearchText(current.addingRequiredFilter(condition))
                    }
                } else if let token = current.requiredFilterTokens.last(where: { $0.field == "from" }) {
                    store.updateSearchText(current.removingRequiredFilter(token))
                }
            }
        }
        .sheet(isPresented: $showsTips) {
            MobileSearchTipsSheet { store.updateSearchText($0) }
        }
    }

    /// Where to look and what to match, plus the rarer actions.
    private var options: some View {
        Menu {
            Picker("Search in", selection: $store.searchScope) {
                ForEach(MailSearchScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Match", selection: $store.searchField) {
                ForEach(MailSearchField.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Section {
                if let onSearchOnline {
                    Button("Search Online…", systemImage: "globe", action: onSearchOnline)
                }
                Button("Search Tips…", systemImage: "lightbulb") { showsTips = true }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Search options")
    }

    private func filter(_ title: String, symbol: String, condition: String, query: MailSearchQuery,
                        token: MailSearchToken?) -> some View {
        chip(title, symbol: symbol, selected: token != nil) {
            store.updateSearchText(token.map { query.removingRequiredFilter($0) } ?? query.addingRequiredFilter(condition))
        }
    }

    /// Leaves Trash and Junk out of the results, or brings them back.
    private func trashFilter(_ query: MailSearchQuery) -> some View {
        let isTrash: (MailSearchToken) -> Bool = {
            $0.isExcluded && $0.field == "in" && ["trash", "junk", "spam"].contains($0.value.lowercased())
        }
        let selected = query.tokens.contains(where: isTrash)
        return chip("No Trash or Junk", symbol: "trash.slash", selected: selected) {
            if selected {
                // Positions shift as terms are removed, so look each one up again.
                var text = store.searchText
                while let token = MailSearchQuery(source: text).tokens.first(where: isTrash) {
                    let next = MailSearchQuery(source: text).removingToken(id: token.id)
                    guard next != text else { break }
                    text = next
                }
                store.updateSearchText(text)
            } else {
                store.updateSearchText(query.addingRequiredFilter(MailSearchQuery.withoutTrashOrJunk))
            }
        }
        .accessibilityLabel("Exclude Trash and Junk")
    }

    private func chip(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark" : symbol).font(.system(size: 11, weight: .bold))
                Text(title).lineLimit(1)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(palette.accent).interactive() : .regular.interactive(), in: Capsule())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

/// Pick a sender to filter by, from people in this mailbox or typed by hand.
private struct MobileSenderFilterSheet: View {
    let store: MailStore
    let initial: String
    let canRemove: Bool
    /// The chosen sender, or nil to remove the filter.
    let onDone: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var focused: Bool

    private var value: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var suggestions: [MailMessage] {
        var seen = Set<String>()
        var matches: [MailMessage] = []
        for message in store.messages {
            let email = message.senderEmail
            guard !email.isEmpty, !message.isOutgoing, store.isAccountVisible(message),
                  value.isEmpty || email.localizedStandardContains(value) || message.sender.localizedStandardContains(value),
                  seen.insert(email.lowercased()).inserted else { continue }
            matches.append(message)
            if matches.count == 8 { break }
        }
        return matches
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name or email address", text: $input)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { if !value.isEmpty { apply(value) } }
                }
                .mobileSheetRows()
                Section {
                    ForEach(suggestions) { message in
                        Button { apply(message.senderEmail) } label: {
                            HStack(spacing: 12) {
                                ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(message.sender.isEmpty ? message.senderEmail : message.sender)
                                        .foregroundStyle(.primary).lineLimit(1)
                                    Text(message.senderEmail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .mobileSheetRows()
                if canRemove {
                    Section {
                        Button("Remove Filter", role: .destructive) { onDone(nil); dismiss() }
                    }
                    .mobileSheetRows()
                }
            }
            .navigationTitle("From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", systemImage: "checkmark") { apply(value) }.disabled(value.isEmpty)
                }
            }
            .onAppear { input = initial; focused = true }
        }
        .mobileSheetDetents()
    }

    private func apply(_ sender: String) {
        onDone(sender)
        dismiss()
    }
}

/// Examples of search conditions; tapping one puts it in the search field.
private struct MobileSearchTipsSheet: View {
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette

    private let examples: [(String, String)] = [
        ("from:clara", "From a person or address"),
        ("to:alex", "Sent to a person or address"),
        ("subject:\"design review\"", "An exact phrase in the subject"),
        ("after:2026-11-01 before:2026-12-01", "A date range"),
        ("has:attachment filetype:pdf", "Messages with PDF files"),
        ("is:unread -is:starred", "Unread, but not starred"),
        ("is:vip OR is:needsreply", "VIP senders or Needs Reply"),
        ("-in:trash -in:junk", "Leave out Trash and Junk"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(examples, id: \.0) { query, explanation in
                        Button {
                            onUse(query)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(query).font(.system(.subheadline, design: .monospaced).weight(.medium)).foregroundStyle(palette.accent)
                                Text(explanation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Spaces mean all conditions must match. Use OR for alternatives, quotes for phrases, and a minus sign to leave something out. Search covers mail on this iPhone; use Search Online for older mail.")
                }
                .mobileSheetRows()
            }
            .navigationTitle("Search Tips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
        }
        .mobileSheetDetents()
    }
}
