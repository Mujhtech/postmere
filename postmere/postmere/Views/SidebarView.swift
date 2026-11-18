import SwiftUI

struct SidebarView: View {
    @Bindable var store: MailStore
    var onSelect: (() -> Void)?
    @State private var showsViewEditor = false
    @State private var editingSavedView: SavedInboxView?
    private var accounts: [MailAccount] { MailAccount.allCases }

    private var mailboxSelection: Binding<String?> {
        Binding(
            get: { store.selectedSavedViewID.map { "view:\($0.uuidString)" } ?? store.selectedAccount.map { "account:\($0)" } ?? store.selectedMailbox.rawValue },
            set: {
                guard let value = $0 else { return }
                if value.hasPrefix("account:") { store.selectAccount(String(value.dropFirst(8))) }
                else if value.hasPrefix("view:"), let id = UUID(uuidString: String(value.dropFirst(5))) { store.selectSavedView(id) }
                else if let mailbox = Mailbox(rawValue: value) { store.selectMailbox(mailbox) }
                onSelect?()
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: mailboxSelection) {
                Section("Favorites") {
                    ForEach([Mailbox.inbox, .starred, .needsReply]) { mailbox in
                        mailboxRow(mailbox)
                    }
                }

                Section("Later") {
                    ForEach([Mailbox.snoozed, .followUps, .newSenders]) { mailbox in
                        mailboxRow(mailbox)
                    }
                }

                Section {
                    ForEach(store.savedViews) { view in
                        HStack(spacing: 8) {
                            navigationIcon("line.3.horizontal.decrease.circle", selected: store.selectedSavedViewID == view.id)
                            Text(view.name).lineLimit(1)
                        }
                            .font(.system(size: 13))
                            .padding(.vertical, 3)
                            .tag("view:\(view.id.uuidString)")
                            .contextMenu {
                                Button("Edit View…") { editView(view) }
                                Button("Delete View", role: .destructive) { store.deleteSavedView(view.id) }
                            }
                    }
                    if store.savedViews.isEmpty {
                        Button { editView(nil) } label: {
                            HStack(spacing: 8) {
                                navigationIcon("plus")
                                Text("New view…")
                            }
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Saved Views")
                        Spacer()
                        if !store.savedViews.isEmpty {
                            Button { editView(nil) } label: { navigationIcon("plus") }
                                .buttonStyle(.plain)
                                .help("Create a saved inbox view")
                                .accessibilityLabel("Create saved view")
                        }
                    }
                }

                Section("Mailboxes") {
                    ForEach([Mailbox.drafts, .outbox, .sent, .archive, .trash]) { mailbox in
                        mailboxRow(mailbox)
                    }
                }

                if !accounts.isEmpty {
                    Section("Accounts") {
                        ForEach(accounts) { account in
                            accountRow(account)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .listStyle(.sidebar)
            .accessibilityLabel("Mailboxes and account inboxes")

            Divider()

            SettingsLink {
                HStack(spacing: 8) {
                    navigationIcon("gearshape")
                    Text("Settings")
                    Spacer(minLength: 0)
                }
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsViewEditor) { SavedInboxViewEditor(store: store, editing: editingSavedView) }
    }

    private func editView(_ view: SavedInboxView?) {
        editingSavedView = view
        showsViewEditor = true
    }

    private func mailboxRow(_ mailbox: Mailbox) -> some View {
        let selected = store.selectedMailbox == mailbox && store.selectedAccount == nil && store.selectedSavedViewID == nil
        return HStack(spacing: 8) {
            navigationIcon(mailbox.systemImage, selected: selected)
            Text(mailbox == .inbox ? "All Inboxes" : mailbox.title).lineLimit(1)
            Spacer(minLength: 4)
            let count = store.count(for: mailbox)
            if count > 0 && [.inbox, .drafts, .needsReply, .snoozed, .followUps, .newSenders, .outbox].contains(mailbox) {
                Text(count, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(selected ? HierarchicalShapeStyle.primary : .secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 3)
        .tag(mailbox.rawValue)
        .help(mailbox == .inbox ? "Inbox messages from all accounts" : "\(mailbox.title) across all accounts")
        .accessibilityElement(children: .combine)
        .accessibilityValue(mailbox == .inbox ? "\(store.count(for: mailbox)) unread messages" : "\(store.count(for: mailbox)) messages")
    }

    private func accountRow(_ account: MailAccount) -> some View {
        let unread = store.messages.filter { store.matchesMailbox($0, mailbox: .inbox) && $0.account == account.rawValue && $0.isUnread }.count
        let selected = store.selectedAccount == account.rawValue
        return HStack(spacing: 8) {
            navigationIcon("envelope", selected: selected)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 13))
                Text(account.isConnected ? account.email : "\(account.email) · Reconnect")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? HierarchicalShapeStyle.primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if unread > 0 {
                Text(unread, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(selected ? HierarchicalShapeStyle.primary : .secondary)
            }
        }
        .padding(.vertical, 3)
        .tag("account:\(account.rawValue)")
        .help("\(account.name) Inbox · \(account.email)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.name) Inbox, \(account.email)")
        .accessibilityValue("\(unread) unread messages")
    }

    private func navigationIcon(_ name: String, selected: Bool = false) -> some View {
        PostmereIcon(name, size: 14)
            .foregroundStyle(selected ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(PostmereTheme.icon))
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}
