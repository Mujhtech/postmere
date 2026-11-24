import Contacts
import SwiftUI

// MARK: - Accounts

/// Every connected mailbox: name it, reconnect it, disconnect it, and pick the one new mail is sent from.
struct MobileAccountsSettings: View {
    let runtime: MailRuntime
    @Environment(\.postmereAccent) private var palette
    @AppStorage("defaultSendingAccount") private var defaultSendingAccount = ""
    @State private var connection = MailAccountConnection()
    @State private var calendarAccess = false
    @State private var renaming: BackendAccount?
    @State private var disconnecting: BackendAccount?
    @State private var busyAccount: UUID?

    private var session: BackendSession { runtime.backend }
    private var store: MailStore { runtime.store }

    var body: some View {
        List {
            Section {
                ForEach(session.accounts) { account in row(account) }
                if session.accounts.isEmpty {
                    Text("Add a Gmail or Outlook account to start.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Tap ••• to rename, reconnect or disconnect an account.")
            }
            Section {
                MobileProviderButtons(runtime: runtime, connection: connection, calendarAccess: calendarAccess)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                Toggle("Include calendar access", isOn: $calendarAccess)
                    .disabled(connection.provider != nil)
            } header: {
                Text("Add account")
            } footer: {
                Text("Calendar access lets you RSVP and use booking links. To add it to an existing account, turn this on and reconnect.")
            }
            if MailAccount.sendingAccounts.count > 1 {
                Section {
                    Picker("Send new mail from", selection: $defaultSendingAccount) {
                        ForEach(MailAccount.sendingAccounts, id: \.rawValue) { account in
                            Text(account.title).tag(account.rawValue)
                        }
                    }
                } footer: {
                    Text("Replies always go from the account that received the message.")
                }
            }
            if !store.previousAccountDrafts.isEmpty {
                Section {
                    ForEach(store.previousAccountDrafts) { draft in
                        Button {
                            store.reviewPreviousAccountDraft(id: draft.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MailMessage.displaySubject(draft.subject)).foregroundStyle(.primary).lineLimit(1)
                                Text(draft.providerAccountEmail ?? draft.senderEmail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(store.isComposing)
                    }
                } header: {
                    Text("Earlier drafts")
                } footer: {
                    Text("Drafts from accounts that were removed. Open one and choose a connected account before sending.")
                }
            }
            if let error = session.errorMessage {
                Section { Text(error).foregroundStyle(PostmereTheme.destructiveInk) }
            }
        }
        .mobileSettingsCanvas()
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if defaultSendingAccount.isEmpty { defaultSendingAccount = MailAccount.sendingAccounts.first?.rawValue ?? "" }
        }
        .onDisappear(perform: connection.cancel)
        .sheet(item: $renaming) { MobileAccountRenameSheet(account: $0, session: session) }
        .sheet(item: $connection.newAccount) { MobileAccountRenameSheet(account: $0, session: session, isNew: true) }
        .confirmationDialog("Disconnect this account?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible, presenting: disconnecting) { account in
            Button("Disconnect \(account.name ?? account.email)", role: .destructive) { disconnect(account) }
        } message: { _ in
            Text("Syncing stops and pending sends are cancelled. Mail already on this iPhone stays.")
        }
    }

    private func row(_ account: BackendAccount) -> some View {
        let connected = account.status == "connected"
        let synced = account.lastSyncedAt.map { "synced \($0.formatted(.relative(presentation: .named)))" }
        return HStack(spacing: 12) {
            MobileAccountAvatar(address: account.email, name: account.name ?? account.displayName ?? "",
                                provider: account.provider, size: 38)
                .opacity(connected ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name ?? account.email).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([account.name == nil ? nil : account.email, Brand.providerName(account.provider),
                      connected ? synced : "needs reconnecting"].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if busyAccount == account.id {
                ProgressView()
            } else {
                if !connected {
                    Button("Reconnect") { reconnect(account) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .buttonStyle(.plain)
                }
                Menu {
                    let local = MailAccount.allCases.first { $0.email.caseInsensitiveCompare(account.email) == .orderedSame }
                    Button(account.name == nil ? "Name Account…" : "Rename…", systemImage: "pencil") { renaming = account }
                    if let local {
                        NavigationLink {
                            MobileSignatureEditor(accountID: local.rawValue, title: local.title)
                        } label: {
                            Label("Signature", systemImage: "signature")
                        }
                    }
                    Button("Reconnect…", systemImage: "arrow.clockwise") { reconnect(account) }
                    Divider()
                    Button("Disconnect…", systemImage: "minus.circle", role: .destructive) { disconnecting = account }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                }
                .disabled(connection.provider != nil)
            }
        }
        .padding(.vertical, 2)
    }

    private func reconnect(_ account: BackendAccount) {
        connection.start(account.provider, session: session, reconnecting: account, calendarAccess: calendarAccess) {
            await runtime.sync()
        }
    }

    private func disconnect(_ account: BackendAccount) {
        disconnecting = nil
        busyAccount = account.id
        Task {
            defer { busyAccount = nil }
            do {
                try await session.disconnectAccount(id: account.id)
                await runtime.sync()
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
    }
}

/// A short name like "Work" or "Personal", shown instead of the address.
struct MobileAccountRenameSheet: View {
    let account: BackendAccount
    let session: BackendSession
    var isNew = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        MobileAccountAvatar(address: account.email, name: account.displayName ?? "", provider: account.provider, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.email).font(.subheadline.weight(.semibold))
                            if let provider = Brand.providerName(account.provider) {
                                Text(provider).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    TextField("Work, Personal…", text: $name).focused($focused).submitLabel(.done).onSubmit(save)
                    HStack {
                        ForEach(["Work", "Personal", "Side project"], id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                        }
                    }
                } footer: {
                    Text(isNew ? "Connected. Give it a name to tell your accounts apart, or skip." : "Leave empty to show the address.")
                }
                if let error { Section { Text(error).foregroundStyle(PostmereTheme.destructiveInk) } }
            }
            .navigationTitle(isNew ? "Name Account" : "Rename Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isNew ? "Skip" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save", systemImage: "checkmark", action: save) }
                }
            }
            .onAppear { name = account.name ?? ""; focused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await session.renameAccount(accountID: account.id, name: name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Notifications

/// Turn alerts on per account, hide subjects, and set quiet hours.
struct MobileNotificationSettings: View {
    let runtime: MailRuntime
    @State private var account = MailAccount.allCases.first?.rawValue ?? ""

    private var notifications: MailNotificationService { runtime.notifications }

    private var profile: Binding<NotificationProfile> {
        Binding(get: {
            notifications.profiles.first { $0.id == account } ?? NotificationProfile(id: account)
        }, set: { profile in
            guard !profile.id.isEmpty else { return }
            if let index = notifications.profiles.firstIndex(where: { $0.id == profile.id }) {
                notifications.profiles[index] = profile
            } else {
                notifications.profiles.append(profile)
            }
        })
    }

    var body: some View {
        Form {
            Section {
                switch notifications.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    LabeledContent("Notifications", value: "Allowed")
                case .denied:
                    Button("Allow in iOS Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { MailPlatform.open(url) }
                    }
                default:
                    Button("Turn On Notifications") { Task { await notifications.requestAuthorization() } }
                }
            } footer: {
                if let error = notifications.authorizationError { Text(error) }
            }
            if !MailAccount.allCases.isEmpty {
                Section {
                    if MailAccount.allCases.count > 1 {
                        Picker("Account", selection: $account) {
                            ForEach(MailAccount.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    }
                    Toggle("Alerts", isOn: profile.enabled)
                    if profile.wrappedValue.enabled {
                        Toggle("Show subject", isOn: profile.showPreview)
                        Toggle("Only at certain times", isOn: profile.scheduleEnabled)
                        if profile.wrappedValue.scheduleEnabled {
                            DatePicker("From", selection: minute(\.startMinute), displayedComponents: .hourAndMinute)
                            DatePicker("Until", selection: minute(\.endMinute), displayedComponents: .hourAndMinute)
                            weekdayPicker
                        }
                    }
                } header: {
                    Text("Per account")
                } footer: {
                    if let error = notifications.lastError {
                        Text(error)
                    } else if profile.wrappedValue.scheduleEnabled {
                        Text("Alerts arrive only during these hours. Mail still syncs the rest of the time.")
                    }
                }
                Section {
                    Button("Focus Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { MailPlatform.open(url) }
                    }
                } footer: {
                    Text("Use a Focus filter in iOS Settings to choose which accounts can alert during a Focus.")
                }
            }
        }
        .mobileSettingsCanvas()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refreshAuthorization() }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                let day = index + 1
                let on = profile.wrappedValue.weekdays.contains(day)
                Button {
                    if on { profile.wrappedValue.weekdays.remove(day) } else { profile.wrappedValue.weekdays.insert(day) }
                } label: {
                    Text(symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(on ? .white : .primary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Mobile.raised), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[index])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func minute(_ key: WritableKeyPath<NotificationProfile, Int>) -> Binding<Date> {
        Binding(get: {
            let value = profile.wrappedValue[keyPath: key]
            return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            profile.wrappedValue[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

// MARK: - Inbox tabs and VIPs

/// Show, hide, reorder, add and edit tabs, and choose what happens when mail fits several.
struct MobileInboxTabsSettings: View {
    @Bindable var store: MailStore
    @State private var editing: InboxSplit?

    var body: some View {
        List {
            Section {
                ForEach(store.inboxSplits) { split in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { !split.isHidden },
                                             set: { store.setInboxSplitHidden(split.id, hidden: !$0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(split.name)
                                Text(split.criteria.query.isEmpty ? "All matching inbox mail" : split.criteria.query)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .swipeActions(edge: .leading) {
                        Button("Edit", systemImage: "pencil") { editing = split }.tint(.blue)
                    }
                    .contextMenu {
                        Button("Edit Tab…", systemImage: "pencil") { editing = split }
                        Button("Remove Tab", systemImage: "trash", role: .destructive) { store.deleteInboxSplit(split.id) }
                    }
                }
                .onMove { from, to in
                    guard let index = from.first else { return }
                    let id = store.inboxSplits[index].id
                    store.moveInboxSplit(id: id, to: to > index ? to - 1 : to)
                }
                .onDelete { offsets in
                    for index in offsets { store.deleteInboxSplit(store.inboxSplits[index].id) }
                }
                Button {
                    editing = InboxSplit(name: "", criteria: SavedInboxCriteria(mailbox: .inbox))
                } label: {
                    Label("New Tab", systemImage: "plus")
                }
            } footer: {
                Text("Tabs group the inbox without moving mail. Swipe right to edit, or tap Edit to reorder.")
            }
            Section {
                Picker("When mail fits several tabs", selection: $store.inboxSplitOverlapPolicy) {
                    ForEach(InboxSplitOverlapPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(store.inboxSplitOverlapPolicy.explanation)
            }
            Section {
                NavigationLink { MobileVIPSettings(store: store) } label: {
                    LabeledContent("VIP People & Domains", value: store.vipContacts.count.formatted())
                }
            } footer: {
                Text("Mail from VIPs lands in Important. Use is:vip in any search or tab.")
            }
        }
        .mobileSettingsCanvas()
        .navigationTitle("Inbox Tabs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editing) { MobileInboxTabEditor(store: store, split: $0) }
    }
}

struct MobileInboxTabEditor: View {
    @Bindable var store: MailStore
    @State var split: InboxSplit
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var isExisting: Bool { store.inboxSplits.contains { $0.id == split.id } }
    private var isValid: Bool {
        !split.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && MailSearchQuery(source: split.criteria.query, defaultField: split.criteria.searchField).isValid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name, like Receipts", text: $split.name) }
                MailCriteriaFields(criteria: $split.criteria, showsMailbox: false)
                if let error { Section { Text(error).foregroundStyle(PostmereTheme.destructiveInk) } }
                if isExisting {
                    Section {
                        Button("Remove Tab", role: .destructive) { store.deleteInboxSplit(split.id); dismiss() }
                    }
                }
            }
            .navigationTitle(isExisting ? "Edit Tab" : "New Tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        if store.saveInboxSplit(split) { dismiss() } else { error = store.operationError }
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

struct MobileVIPSettings: View {
    @Bindable var store: MailStore
    @State private var value = ""
    @State private var kind: VIPContact.Kind = .person
    @State private var account: String?
    @State private var includeSubdomains = true
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Match", selection: $kind) {
                    Text("Person").tag(VIPContact.Kind.person)
                    Text("Domain").tag(VIPContact.Kind.domain)
                }
                .pickerStyle(.segmented)
                TextField(kind == .person ? "person@example.com" : "example.com", text: $value)
                    .keyboardType(kind == .person ? .emailAddress : .URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if MailAccount.allCases.count > 1 {
                    Picker("Account", selection: $account) {
                        Text("All accounts").tag(nil as String?)
                        ForEach(MailAccount.allCases) { Text($0.title).tag(Optional($0.rawValue)) }
                    }
                }
                if kind == .domain { Toggle("Include subdomains", isOn: $includeSubdomains) }
                Button("Add VIP") {
                    let contact = VIPContact(value: value, kind: kind, account: account, includeSubdomains: includeSubdomains)
                    if store.saveVIPContact(contact) { value = ""; error = nil }
                    else { error = store.operationError ?? "Check the address or domain." }
                }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Add")
            } footer: {
                if let error { Text(error).foregroundStyle(PostmereTheme.destructiveInk) }
            }
            Section("VIPs") {
                if store.vipContacts.isEmpty {
                    Text("No VIPs yet.").foregroundStyle(.secondary)
                }
                ForEach(store.vipContacts) { contact in
                    HStack(spacing: 12) {
                        ParticipantPhoto(address: contact.kind == .person ? contact.value : "hello@\(contact.value)", name: "", size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.kind == .domain ? "Everyone at \(contact.value)" : contact.value).lineLimit(1)
                            Text(MailAccount.scopeLabel(for: contact.account, providerEmail: contact.providerAccountEmail))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { store.deleteVIPContact(contact.id) }
                    }
                }
            }
        }
        .mobileSettingsCanvas()
        .navigationTitle("VIPs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sender rules

/// Where mail from particular senders goes, plus screening of first-time senders.
struct MobileSenderRulesSettings: View {
    @Bindable var store: MailStore
    @State private var address = ""
    @State private var route: SenderRoute = .archive

    private var canAdd: Bool {
        let list = MailAddressList(address)
        return list.addresses.count == 1 && list.invalid.isEmpty
    }

    var body: some View {
        List {
            Section {
                Toggle("Screen new senders", isOn: $store.senderScreeningEnabled)
            } footer: {
                Text("Mail from people you haven’t heard from before waits in New Senders until you accept or block them.")
            }
            Section {
                TextField("name@example.com", text: $address)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Picker("Send to", selection: $route) {
                    ForEach(SenderRoute.allCases) { Text($0.title).tag($0) }
                }
                Button("Add Rule", action: add).disabled(!canAdd)
            } header: {
                Text("Add a rule")
            }
            ForEach(SenderRoute.allCases) { route in
                let rules = store.senderRules.filter { $0.route == route }
                if !rules.isEmpty {
                    Section(route.title) {
                        ForEach(rules) { rule in
                            HStack(spacing: 12) {
                                ParticipantPhoto(address: rule.domain.map { "hello@\($0)" } ?? rule.email, name: "", size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rule.domain.map { "Everyone at \($0)" } ?? rule.email).lineLimit(1)
                                    Text(MailAccount.scopeLabel(for: rule.account, providerEmail: rule.providerAccountEmail))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) { store.deleteSenderRule(rule.id) }
                            }
                            .contextMenu {
                                ForEach(SenderRoute.allCases.filter { $0 != rule.route }) { other in
                                    Button("Send to \(other.title)") {
                                        var changed = rule
                                        changed.route = other
                                        store.saveSenderRule(changed)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .mobileSettingsCanvas()
        .navigationTitle("Sender Rules")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        guard canAdd, let email = MailAddressList(address).addresses.first else { return }
        store.saveSenderRule(SenderRule(email: email, route: route))
        address = ""
    }
}

// MARK: - Sender photos

/// Where sender photos come from: Contacts, company icons, Gravatar.
struct MobileSenderPhotoSettings: View {
    @AppStorage("showContactPhotos") private var showContactPhotos = true
    @State private var photos = MailContactPhotos.shared
    @Bindable private var websiteIcons = MailRemoteParticipantImages.websiteIcons
    @Bindable private var gravatar = MailRemoteParticipantImages.gravatar

    var body: some View {
        Form {
            Section {
                Toggle("Show photos in the list", isOn: $showContactPhotos)
            }
            Section {
                switch photos.authorization {
                case .notDetermined:
                    Button("Use Photos from Contacts") { Task { await photos.requestAccess() } }
                case .authorized, .limited:
                    LabeledContent("Contacts", value: "Allowed")
                default:
                    Button("Allow Contacts in iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { MailPlatform.open(url) }
                    }
                }
            } footer: {
                Text("Photos from your address book. They never leave this iPhone.")
            }
            Section {
                Toggle("Company icons", isOn: $websiteIcons.enabled)
            } footer: {
                Text("Looks up a company’s icon by sending its domain to Bitwarden’s icon service.")
            }
            Section {
                Toggle("Gravatar", isOn: $gravatar.enabled)
            } footer: {
                Text("Sends a hash of the sender’s address to Gravatar.")
            }
        }
        .mobileSettingsCanvas()
        .navigationTitle("Sender Photos")
        .navigationBarTitleDisplayMode(.inline)
    }
}
