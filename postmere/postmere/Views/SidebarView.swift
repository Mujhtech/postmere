import SwiftUI

struct SidebarView: View {
    @Bindable var store: MailStore
    var onSelect: (() -> Void)?
    @State private var showsViewEditor = false
    @State private var editingSavedView: SavedInboxView?
    @Environment(MailRuntime.self) private var runtime
    @Environment(\.postmereAccent) private var accent
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
        let counts = runtime.mailboxCounts.snapshot
        let current = counts?.accounts == store.searchableAccounts ? counts : nil
        VStack(spacing: 0) {
            List(selection: mailboxSelection) {
                Section("Favorites") {
                    ForEach([Mailbox.inbox, .starred, .needsReply]) { mailbox in
                        mailboxRow(mailbox, count: current?.mailboxes[mailbox, default: 0])
                    }
                }

                Section("Later") {
                    ForEach([Mailbox.snoozed, .followUps, .newSenders]) { mailbox in
                        mailboxRow(mailbox, count: current?.mailboxes[mailbox, default: 0])
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
                            .mailSelection(store.selectedSavedViewID == view.id)
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
                        mailboxRow(mailbox, count: current?.mailboxes[mailbox, default: 0])
                    }
                }

                if !accounts.isEmpty {
                    Section("Accounts") {
                        ForEach(accounts) { account in
                            accountRow(account, unread: current?.unreadByAccount[account.rawValue, default: 0])
                        }
                    }
                }
            }
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
                .foregroundStyle(sidebarSecondary)
                SidebarSyncIndicator(activity: runtime.mailSyncActivity)
                    .layoutPriority(1)
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

    private func mailboxRow(_ mailbox: Mailbox, count: Int?) -> some View {
        let selected = store.selectedMailbox == mailbox && store.selectedAccount == nil && store.selectedSavedViewID == nil
        return HStack(spacing: 8) {
            navigationIcon(mailbox.systemImage, selected: selected)
            Text(mailbox == .inbox ? "All Inboxes" : mailbox.title).lineLimit(1)
            Spacer(minLength: 4)
            if let count, count > 0, [.inbox, .drafts, .needsReply, .snoozed, .followUps, .newSenders, .outbox].contains(mailbox) {
                Text(count, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(selected ? AnyShapeStyle(accent.selectionSecondaryInk) : AnyShapeStyle(.secondary))
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 3)
        .mailSelection(selected)
        .tag(mailbox.rawValue)
        .help(mailbox == .inbox ? "Inbox messages from all accounts" : "\(mailbox.title) across all accounts")
        .accessibilityElement(children: .combine)
        .accessibilityValue(count.map { mailbox == .inbox ? "\($0) unread messages" : "\($0) messages" } ?? "Loading count")
    }

    private func accountRow(_ account: MailAccount, unread: Int?) -> some View {
        let selected = store.selectedSavedViewID == nil && store.selectedAccount == account.rawValue
        return HStack(spacing: 8) {
            navigationIcon("envelope", selected: selected)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 13))
                Text(account.isConnected ? account.email : "\(account.email) · Reconnect")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(accent.selectionSecondaryInk) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let unread, unread > 0 {
                Text(unread, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(selected ? AnyShapeStyle(accent.selectionSecondaryInk) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, 3)
        .mailSelection(selected)
        .tag("account:\(account.rawValue)")
        .help("\(account.name) Inbox · \(account.email)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.name) Inbox, \(account.email)")
        .accessibilityValue(unread.map { "\($0) unread messages" } ?? "Loading count")
    }

    private func navigationIcon(_ name: String, selected: Bool = false) -> some View {
        PostmereIcon(name, size: 14)
            .foregroundStyle(selected ? accent.selectionInk : PostmereTheme.icon)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}
