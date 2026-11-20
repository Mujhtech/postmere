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
        .mailPanelSurface()
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
            .mailPanelSurface()
    }
}

struct InboxTabsView: View {
    @Environment(\.postmereAccent) private var palette
    @Bindable var store: MailStore
    let onManage: () -> Void

    @State private var loadedCounts: (key: InboxTabCountKey, counts: InboxTabCounts)?

    private let rowHeight: CGFloat = 27
    private let tabPadding: CGFloat = 9
    private let spacing: CGFloat = 5

    var body: some View {
        let key = store.inboxTabCountKey
        let counts = loadedCounts.flatMap { result in
            result.key.account == key.account && result.key.accounts == key.accounts ? result.counts : nil
        }
        GeometryReader { geometry in
            let tabs = fittingTabs(width: geometry.size.width, counts: counts)
            HStack(spacing: spacing) {
                tab("All", id: nil, count: counts?.all).fixedSize()
                ForEach(tabs.visible) { split in
                    tab(split.name, id: split.id, count: counts.map { $0.splits[split.id] ?? 0 })
                }
                Spacer(minLength: 0)
                moreTabs(tabs.overflow, counts: counts?.splits ?? [:])
            }
        }
        .task(id: key) {
            let counts = await store.loadInboxTabCounts()
            guard !Task.isCancelled, key == store.inboxTabCountKey else { return }
            loadedCounts = (key, counts)
        }
        .task(id: store.hasSearchCriteria ? nil : key, priority: .utility) {
            await store.prepareInboxTabs()
        }
        .frame(height: rowHeight)
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    private func fittingTabs(width: CGFloat, counts: InboxTabCounts?) -> (visible: [InboxSplit], overflow: [InboxSplit]) {
        let splits = store.visibleInboxSplits
        let selected = splits.first { $0.id == store.selectedInboxSplitID }
        var available = width - rowHeight - 2 * spacing - tabWidth("All", count: counts?.all)
        // Reserve space for the selected tab. Even a very long selected name has a place and a tooltip.
        if let selected { available -= tabWidth(selected.name, count: counts?.splits[selected.id]) + spacing }
        var visible: [InboxSplit] = []
        var overflow: [InboxSplit] = []
        for split in splits {
            if split.id == selected?.id {
                visible.append(split)
                continue
            }
            if !overflow.isEmpty {
                overflow.append(split)
                continue
            }
            let needed = tabWidth(split.name, count: counts?.splits[split.id]) + spacing
            if needed <= available {
                visible.append(split)
                available -= needed
            } else {
                overflow.append(split)
            }
        }
        return (visible, overflow)
    }

    private func tabWidth(_ title: String, count: Int?) -> CGFloat {
        // Measure the selected weight so clicking a visible tab never pushes a sibling into the menu.
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        guard let count, count > 0 else { return 2 * tabPadding + titleWidth }
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let countWidth = ceil((count.formatted() as NSString).size(withAttributes: [.font: digits]).width)
        return 2 * tabPadding + titleWidth + 5 + countWidth
    }

    @ViewBuilder
    private func moreTabs(_ overflow: [InboxSplit], counts: [UUID: Int]) -> some View {
        if overflow.isEmpty {
            Button(action: onManage) {
                moreIcon
            }
            .buttonStyle(.plain)
            .help("Manage inbox tabs and VIPs")
            .accessibilityLabel("Manage inbox tabs and VIPs")
        } else {
            Menu {
                ForEach(overflow) { split in
                    let count = counts[split.id] ?? 0
                    Button(count > 0 ? "\(split.name) (\(count.formatted()))" : split.name) {
                        store.selectInboxSplit(split.id)
                    }
                }
                Divider()
                Button("Manage Inbox Tabs and VIPs…", action: onManage)
            } label: {
                moreIcon
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More inbox tabs")
            .help("More inbox tabs")
        }
    }

    private var moreIcon: some View {
        PostmereIcon("ellipsis.circle", size: 16)
            .foregroundStyle(.secondary)
            .frame(width: rowHeight, height: rowHeight)
            .contentShape(Rectangle())
    }

    private func tab(_ title: String, id: UUID?, count: Int?) -> some View {
        let selected = store.selectedInboxSplitID == id
        return Button { store.selectInboxSplit(id) } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if let count, count > 0 {
                    Text(count.formatted())
                        .monospacedDigit()
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize()
                }
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? palette.accentInk : .secondary)
            .padding(.horizontal, tabPadding).frame(height: rowHeight)
            .background(selected ? palette.accentInk.opacity(0.10) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(title)
            .accessibilityLabel("\(title) inbox tab")
            .accessibilityValue(count.map { $0 == 1 ? "1 unread conversation" : "\($0.formatted()) unread conversations" } ?? "Loading unread count")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
