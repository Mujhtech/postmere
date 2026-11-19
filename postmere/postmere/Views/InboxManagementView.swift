import SwiftUI

/// The same criteria controls are used by saved views and inbox tabs.
struct MailCriteriaFields: View {
    @Binding var criteria: SavedInboxCriteria
    var showsMailbox = true

    var body: some View {
        Section("Match messages") {
            TextField("Search rule", text: $criteria.query, prompt: Text("from:alex has:attachment"))
            Picker("Search plain text in", selection: $criteria.searchField) {
                ForEach(MailSearchField.allCases) { Text($0.title).tag($0) }
            }
            if showsMailbox {
                Picker("Mailbox", selection: $criteria.mailbox) {
                    Text("All mailboxes").tag(nil as Mailbox?)
                    ForEach(Mailbox.allCases) { Text($0.title).tag(Optional($0)) }
                }
            }
            Picker("Account", selection: $criteria.account) {
                Text("All accounts").tag(nil as String?)
                ForEach(MailAccount.allCases) { Text($0.name).tag(Optional($0.rawValue)) }
            }
            TextField("Sender contains", text: $criteria.sender)
            TextField("Sender domain", text: $criteria.domain, prompt: Text("example.com"))
            Toggle("Unread only", isOn: $criteria.unreadOnly)
            Toggle("With attachments", isOn: $criteria.attachmentsOnly)
            Toggle("Starred only", isOn: $criteria.starredOnly)
            let issues = MailSearchQuery(source: criteria.query, defaultField: criteria.searchField).issues
            if let issue = issues.first {
                Text(issue.message).font(.caption).foregroundStyle(.red)
            } else {
                Text("Combine conditions with spaces. Use OR for alternatives and a minus sign to exclude a condition.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InboxManagementView: View {
    @Bindable var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @State private var editingSplit: InboxSplit?
    @State private var vipValue = ""
    @State private var vipKind: VIPContact.Kind = .person
    @State private var vipAccount: String?
    @State private var includeSubdomains = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            PostmereSheetHeader("Organize your inbox")
            Picker("Organization", selection: $section) {
                Text("Inbox tabs").tag(0)
                Text("VIPs").tag(1)
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if section == 0 { splitSettings } else { vipSettings }
        }
        .frame(width: 640, height: 560)
        .sheet(item: $editingSplit) { split in
            InboxSplitEditor(store: store, split: split)
        }
    }

    private var splitSettings: some View {
        Form {
            Section {
                Picker("When a message matches several tabs", selection: $store.inboxSplitOverlapPolicy) {
                    ForEach(InboxSplitOverlapPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(store.inboxSplitOverlapPolicy.explanation)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Tabs") {
                ForEach(Array(store.inboxSplits.enumerated()), id: \.element.id) { index, split in
                    HStack(spacing: 12) {
                        Toggle("Show \(split.name)", isOn: Binding(get: { !split.isHidden }, set: {
                            store.setInboxSplitHidden(split.id, hidden: !$0)
                        })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(split.name).fontWeight(.medium)
                            Text(split.criteria.query.isEmpty ? "All matching inbox messages" : split.criteria.query)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        orderButton("Move \(split.name) up", symbol: "chevron.up", disabled: index == 0) {
                            store.moveInboxSplit(id: split.id, to: index - 1)
                        }
                        orderButton("Move \(split.name) down", symbol: "chevron.down", disabled: index == store.inboxSplits.count - 1) {
                            store.moveInboxSplit(id: split.id, to: index + 1)
                        }
                        Button("Edit") { editingSplit = split }.controlSize(.small)
                    }.padding(.vertical, 3)
                }
                Button {
                    editingSplit = InboxSplit(name: "", criteria: SavedInboxCriteria(mailbox: .inbox))
                } label: { PostmereLabel("New inbox tab", symbol: "plus", size: 13) }
                Text("All Inbox always includes every inbox message. Tabs organize the view without moving mail.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button("Manage VIP people and domains") { section = 1 }
            }
        }.formStyle(.grouped)
    }

    private var vipSettings: some View {
        Form {
            Section("Add a VIP") {
                Picker("Match", selection: $vipKind) {
                    Text("Email address").tag(VIPContact.Kind.person)
                    Text("Domain").tag(VIPContact.Kind.domain)
                }
                TextField(vipKind == .person ? "Email address" : "Domain", text: $vipValue,
                          prompt: Text(vipKind == .person ? "person@example.com" : "example.com"))
                Picker("Account", selection: $vipAccount) {
                    Text("All accounts").tag(nil as String?)
                    ForEach(MailAccount.allCases) { Text($0.name).tag(Optional($0.rawValue)) }
                }
                if vipKind == .domain { Toggle("Include subdomains", isOn: $includeSubdomains) }
                HStack {
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Button("Add VIP") {
                        let contact = VIPContact(value: vipValue, kind: vipKind, account: vipAccount, includeSubdomains: includeSubdomains)
                        if store.saveVIPContact(contact) { vipValue = ""; error = nil }
                        else { error = store.operationError ?? "Check the address or domain." }
                    }.disabled(vipValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("VIP people and domains") {
                if store.vipContacts.isEmpty {
                    Text("Add the people whose messages should appear in your Important tab.").foregroundStyle(.secondary)
                }
                ForEach(store.vipContacts) { contact in
                    HStack(spacing: 12) {
                        PostmereIcon(contact.kind == .person ? "person.crop.circle" : "building.2", size: 18)
                            .foregroundStyle(PostmereTheme.icon)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contact.value)
                            Text(MailAccount.scopeLabel(for: contact.account, providerEmail: contact.providerAccountEmail)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { store.deleteVIPContact(contact.id) }.controlSize(.small)
                    }
                }
                Text("Use is:vip in any search or inbox tab. VIP status applies to senders; starring applies to individual messages.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }

    private func orderButton(_ label: String, symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { PostmereIcon(symbol, size: 12).frame(width: 20, height: 22) }
            .buttonStyle(.borderless).disabled(disabled).help(label).accessibilityLabel(label)
    }
}

private struct InboxSplitEditor: View {
    @Bindable var store: MailStore
    @State var split: InboxSplit
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var isExisting: Bool { store.inboxSplits.contains { $0.id == split.id } }
    private var isValid: Bool {
        !split.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && MailSearchQuery(source: split.criteria.query, defaultField: split.criteria.searchField).isValid
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isExisting ? "Edit inbox tab" : "New inbox tab")
                .font(PostmereTheme.sheetTitle).frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Form {
                Section { TextField("Name", text: $split.name) }
                MailCriteriaFields(criteria: $split.criteria, showsMailbox: false)
            }.formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
            HStack {
                if isExisting {
                    Button("Remove Tab", role: .destructive) { store.deleteInboxSplit(split.id); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Tab") {
                    if store.saveInboxSplit(split) { dismiss() }
                    else { error = store.operationError }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!isValid)
            }.padding(24)
        }.frame(width: 500, height: 570)
    }
}

struct InboxTabsView: View {
    @Environment(\.postmereAccent) private var palette
    @Bindable var store: MailStore
    let onManage: () -> Void

    var body: some View {
        let counts = store.inboxTabCounts
        HStack(spacing: 5) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    tab("All", id: nil, count: counts.all)
                    ForEach(store.visibleInboxSplits) { split in
                        tab(split.name, id: split.id, count: counts.splits[split.id] ?? 0)
                    }
                }
            }
            Button(action: onManage) {
                PostmereIcon("ellipsis.circle", size: 16).foregroundStyle(PostmereTheme.icon).frame(width: 24, height: 27)
            }.buttonStyle(.plain).help("Manage inbox tabs and VIPs").accessibilityLabel("Manage inbox tabs and VIPs")
        }.padding(.horizontal, 14).padding(.bottom, 11)
    }

    private func tab(_ title: String, id: UUID?, count: Int) -> some View {
        let selected = store.selectedInboxSplitID == id
        return Button { store.selectInboxSplit(id) } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if count > 0 { Text(count.formatted()).monospacedDigit().font(.system(size: 10, weight: .semibold)) }
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? palette.accentInk : .secondary)
            .padding(.horizontal, 9).frame(height: 27)
            .background(selected ? palette.accentInk.opacity(0.10) : .clear, in: .rect(cornerRadius: 6))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(title) inbox tab")
            .accessibilityValue("\(selected ? "Selected, " : "")\(count) unread conversations")
    }
}
