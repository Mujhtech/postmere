import SwiftUI

struct SidebarView: View {
    @Bindable var store: MailStore
    var onSelect: (() -> Void)?
    @State private var showsViewEditor = false
    @State private var editingSavedView: SavedInboxView?
    @AppStorage("sidebarLabelsExpanded") private var labelsExpanded = true
    @Environment(MailRuntime.self) private var runtime
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.postmereAccent) private var accent
    private var accounts: [MailAccount] { MailAccount.allCases }

    // System sidebar labels use vibrancy. Opaque paper themes need explicit
    // foregrounds in the active scheme, including custom icons and section titles.
    private var sidebarText: Color {
        theme == .native ? .primary : (scheme == .dark ? Color(white: 0.95) : Color(white: 0.13))
    }
    private var sidebarSecondary: Color {
        theme == .native ? .secondary : (scheme == .dark ? Color(white: 0.78) : Color(white: 0.34))
    }
    private func rowText(selected: Bool) -> Color { selected ? accent.selectionInk : sidebarText }
    private func rowDetail(selected: Bool) -> Color { selected ? accent.selectionSecondaryInk : sidebarSecondary }

    private var mailboxSelection: Binding<String?> {
        Binding(
            get: {
                // While searching nothing else is selected, so choosing any
                // mailbox, including the one search started from, ends the search.
                store.shownLabelName.map { "label:\($0)" } ?? (store.isSearchActive ? "search" : nil)
                    ?? store.selectedSavedViewID.map { "view:\($0.uuidString)" } ?? store.selectedAccount.map { "account:\($0)" } ?? store.selectedMailbox.rawValue
            },
            set: {
                guard let value = $0 else { return }
                if value.hasPrefix("label:") { store.showLabel(String(value.dropFirst(6))) }
                else if value.hasPrefix("account:") { store.selectAccount(String(value.dropFirst(8))) }
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
                Section {
                    ForEach([Mailbox.inbox, .starred, .needsReply]) { mailbox in
                        mailboxRow(mailbox, count: current?.mailboxes[mailbox, default: 0])
                    }
                } header: { Text("Favorites").foregroundStyle(sidebarSecondary) }

                Section {
                    ForEach([Mailbox.snoozed, .followUps, .newSenders]) { mailbox in
                        mailboxRow(mailbox, count: current?.mailboxes[mailbox, default: 0])
                    }
                } header: { Text("Later").foregroundStyle(sidebarSecondary) }

                Section {
                    ForEach(store.savedViews) { view in
                        let viewSelected = store.selectedSavedViewID == view.id && !store.isSearchActive
                        HStack(spacing: 8) {
                            navigationIcon("line.3.horizontal.decrease.circle", selected: viewSelected)
                            Text(view.name).lineLimit(1).foregroundStyle(rowText(selected: viewSelected))
                        }
                            .font(.system(size: 13))
                            .padding(.vertical, 3)
                            .mailSelection(viewSelected)
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
                                .foregroundStyle(sidebarSecondary)
                        }.buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Saved Views").foregroundStyle(sidebarSecondary)
                        Spacer()
                        if !store.savedViews.isEmpty {
                            Button { editView(nil) } label: { navigationIcon("plus") }
                                .buttonStyle(.plain)
                                .help("Create a saved inbox view")
                                .accessibilityLabel("Create saved view")
                        }
                    }
                }

                let labels = sidebarLabels
                if !labels.isEmpty {
                    Section(isExpanded: $labelsExpanded) {
                        ForEach(labels) { labelRow($0) }
                    } header: { Text("Labels").foregroundStyle(sidebarSecondary) }
                }

                Section {
                    ForEach([Mailbox.drafts, .outbox, .sent, .archive, .junk, .trash]) { mailbox in
                        mailboxRow(mailbox, count: current?.mailboxes[mailbox, default: 0])
                    }
                } header: { Text("Mailboxes").foregroundStyle(sidebarSecondary) }

                if !accounts.isEmpty {
                    Section {
                        ForEach(accounts) { account in
                            accountRow(account, unread: current?.unreadByAccount[account.rawValue, default: 0])
                        }
                    } header: { Text("Accounts").foregroundStyle(sidebarSecondary) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(theme == .native ? .automatic : .hidden)
            .accessibilityLabel("Mailboxes and account inboxes")

            Divider()

            HStack(spacing: 6) {
                SettingsLink {
                    HStack(spacing: 8) {
                        navigationIcon("gearshape")
                        Text("Settings").fixedSize()
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .frame(minHeight: 39)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(sidebarSecondary)
                SidebarSyncIndicator(activity: runtime.mailSyncActivity)
                    .layoutPriority(1)
                AssistantWorkingChip(monitor: runtime.assistants)
            }
            .padding(.horizontal, 14)
        }
        .background(theme == .native ? Color.clear : theme.colors(for: scheme).sidebar)
        .sheet(isPresented: $showsViewEditor) { SavedInboxViewEditor(store: store, editing: editingSavedView) }
        .task(id: labelCatalogKey) { await loadLabelCatalogs() }
    }

    // MARK: Labels

    private struct SidebarLabel: Identifiable {
        let name: String
        let title: String
        let depth: Int
        let unread: Int
        let total: Int
        var id: String { name }
    }

    /// Labels from the shown accounts' catalogs, nested by "/", with unread
    /// counts from downloaded mail outside Junk and Trash.
    private var sidebarLabels: [SidebarLabel] {
        var names = Set<String>()
        var nameByID: [String: String] = [:]
        for (account, labels) in store.labelCatalogs where store.selectedAccount == nil || store.selectedAccount == account {
            for label in labels {
                names.insert(label.name)
                nameByID[label.id] = label.name
            }
        }
        guard !names.isEmpty else { return [] }
        var unread: [String: Int] = [:]
        var total: [String: Int] = [:]
        for message in store.messages where !message.mailbox.isJunkOrTrash {
            var found = Set<String>()
            for id in message.providerLabelIDs { if let name = nameByID[id] { found.insert(name) } }
            for category in message.providerCategories ?? [] where names.contains(category) { found.insert(category) }
            for name in found {
                total[name, default: 0] += 1
                if message.isUnread { unread[name, default: 0] += 1 }
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            return SidebarLabel(name: name, title: parts.last.map(String.init) ?? name, depth: max(0, parts.count - 1),
                                unread: unread[name] ?? 0, total: total[name] ?? 0)
        }
    }

    private func labelRow(_ label: SidebarLabel) -> some View {
        let selected = store.shownLabelName == label.name
        return HStack(spacing: 8) {
            PostmereIcon("tag", size: 14)
                .foregroundStyle(selected ? accent.selectionInk : labelColor(label.name))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label.title).lineLimit(1).foregroundStyle(rowText(selected: selected))
            Spacer(minLength: 4)
            if label.unread > 0 {
                Text(label.unread, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(rowDetail(selected: selected))
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 3)
        .padding(.leading, CGFloat(min(label.depth, 4)) * 14)
        .mailSelection(selected)
        .tag("label:\(label.name)")
        .help("\(label.name) · \(label.total.formatted()) downloaded messages")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Label \(label.name)")
        .accessibilityValue(label.unread > 0 ? "\(label.unread) unread" : "")
    }

    /// A stable colour per label name, so a label is recognisable at a glance.
    private func labelColor(_ name: String) -> Color {
        let hash = name.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: scheme == .dark ? 0.45 : 0.6,
                     brightness: scheme == .dark ? 0.9 : 0.62)
    }

    private var labelCatalogKey: String {
        accounts.filter(\.isConnected).map(\.rawValue).joined(separator: ",") + "|\(runtime.backend.canAccessWorkspace)"
    }

    /// Accounts without label permission are skipped; they still sync mail.
    private func loadLabelCatalogs() async {
        guard runtime.backend.canAccessWorkspace else { store.labelCatalogs = [:]; return }
        var catalogs: [String: [ProviderLabel]] = [:]
        for account in accounts where account.isConnected {
            guard let remote = account.remote,
                  let labels = try? await runtime.backend.labelCatalog(account: remote) else { continue }
            catalogs[account.rawValue] = labels
        }
        if !Task.isCancelled, catalogs != store.labelCatalogs { store.labelCatalogs = catalogs }
    }

    private func editView(_ view: SavedInboxView?) {
        editingSavedView = view
        showsViewEditor = true
    }

    private func mailboxRow(_ mailbox: Mailbox, count: Int?) -> some View {
        let selected = store.selectedMailbox == mailbox && store.selectedAccount == nil && store.selectedSavedViewID == nil && !store.isSearchActive
        return HStack(spacing: 8) {
            navigationIcon(mailbox.systemImage, selected: selected)
            Text(mailbox == .inbox ? "All Inboxes" : mailbox.title).lineLimit(1).foregroundStyle(rowText(selected: selected))
            Spacer(minLength: 4)
            if let count, count > 0, [.inbox, .drafts, .needsReply, .snoozed, .followUps, .newSenders, .outbox].contains(mailbox) {
                Text(count, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(rowDetail(selected: selected))
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
        let selected = store.selectedSavedViewID == nil && store.selectedAccount == account.rawValue && !store.isSearchActive
        return HStack(spacing: 8) {
            navigationIcon("envelope", selected: selected)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .foregroundStyle(rowText(selected: selected))
                    .font(.system(size: 13))
                Text(account.isConnected ? account.email : "\(account.email) · Reconnect")
                    .font(.system(size: 11))
                    .foregroundStyle(rowDetail(selected: selected))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let unread, unread > 0 {
                Text(unread, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(rowDetail(selected: selected))
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
            .foregroundStyle(selected ? accent.selectionInk : sidebarSecondary)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}

/// Shows that a connected assistant is using the mailbox right now.
private struct AssistantWorkingChip: View {
    let monitor: AssistantActivityMonitor
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let working = monitor.connections.filter { $0.isWorking(at: context.date) }
            if let first = working.first {
                Button {
                    settingsTab = "ai"
                    openSettings()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(SettingsTint.green)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(SettingsTint.green.opacity(0.5), lineWidth: 1)
                                .scaleEffect(pulse ? 2.3 : 1).opacity(pulse ? 0 : 1))
                        Text(working.count == 1 ? "\(first.clientName) is working" : "\(working.count) assistants working")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SettingsTint.green.opacity(0.12), in: Capsule())
                    .foregroundStyle(SettingsTint.green)
                }
                .buttonStyle(.plain)
                .help(first.recent.first.map { "Last: \($0.summary)" } ?? "An assistant is using your mail")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
                }
            }
        }
        .animation(.smooth, value: monitor.working.map(\.id))
    }
}

