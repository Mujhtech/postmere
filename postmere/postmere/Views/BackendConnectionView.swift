import SwiftUI

struct BackendConnectionView: View {
    @Bindable var session: BackendSession
    @Bindable var store: MailStore
    @Environment(\.openWindow) private var openWindow
    var onSync: @MainActor @Sendable () async -> Void
    @State private var email = ""
    @State private var password = ""
    /// Held only while choosing between workspaces after a correct password.
    @State private var pendingSecret: String?
    @State private var connection = MailAccountConnection()
    @State private var calendarAccess = false
    @State private var accountToDisconnect: BackendAccount?
    @State private var disconnectingAccountID: UUID?
    @State private var renaming: BackendAccount?

    private var isManagingAccounts: Bool {
        session.isBusy || connection.provider != nil || disconnectingAccountID != nil
    }

    private var serverHost: String {
        URL(string: session.baseURL)?.host() ?? session.baseURL
    }

    var body: some View {
        Form {
            if session.isConnected {
                Section("Workspace") {
                    SettingsRow(session.currentWorkspace?.name ?? serverHost, symbol: "building.2", tint: SettingsTint.indigo,
                                subtitle: session.currentWorkspace == nil ? "Keeps accounts in sync and sends scheduled mail"
                                    : "\(serverHost) · \(session.currentWorkspace?.roleTitle ?? "")") {
                        HStack(spacing: 8) {
                            Button { Task { await onSync() } } label: { PostmereIcon("arrow.clockwise", size: 12) }
                                .controlSize(.small)
                                .disabled(isManagingAccounts || session.accounts.isEmpty)
                                .help("Sync mail now")
                                .accessibilityLabel("Sync mail")
                            Button("Sign Out") { Task { await session.logout() } }
                                .controlSize(.small)
                                .disabled(isManagingAccounts)
                                .help("Also revokes this workspace’s assistant connections")
                        }
                    }
                    if session.workspaces.count > 1, let current = session.currentWorkspace {
                        Picker("Switch workspace", selection: Binding(get: { current.id }, set: { id in
                            Task { await session.switchWorkspace(to: id) }
                        })) {
                            ForEach(session.workspaces) { workspace in
                                Text("\(workspace.name) · \(workspace.roleTitle)").tag(workspace.id)
                            }
                        }
                        .disabled(isManagingAccounts)
                    }
                    statusMessages
                }
                .task(id: session.realtimeGeneration) { await session.refreshWorkspaces() }
                Section("Mail accounts") {
                    ForEach(session.accounts) { account in
                        accountRow(account)
                    }
                    if session.accounts.isEmpty {
                        Text("Add a Google or Outlook account to start.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if connection.provider != nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(connection.reconnectingEmail.map { "Sign in as \($0) in your browser" } ?? "Finish signing in in your browser")
                                .font(.system(size: 12))
                            Spacer()
                            Button("Cancel", action: connection.cancel).controlSize(.small)
                        }
                    }
                    HStack(spacing: 12) {
                        Menu {
                            Button { connect("gmail") } label: { Label { Text("Google") } icon: { Brand.gmail.menuImage() } }
                            Button { connect("microsoft") } label: { Label { Text("Outlook") } icon: { Brand.outlook.menuImage() } }
                        } label: {
                            Label("Add Account", systemImage: "plus")
                        }
                        .fixedSize()
                        .disabled(isManagingAccounts)
                        Spacer()
                        Toggle("Calendar access", isOn: $calendarAccess)
                            .toggleStyle(.switch).controlSize(.mini)
                            .font(.system(size: 12))
                            .disabled(isManagingAccounts)
                            .help("For booking and RSVP. To add it later, turn this on and reconnect.")
                    }
                }
                Section("This Mac") { CalendarIntegrationSettingsView() }
            } else {
                Section {
                    SettingsRow("Sign in to your workspace", symbol: "building.2", tint: SettingsTint.indigo,
                                subtitle: "Use the details from your administrator") { EmptyView() }
                    if let choices = session.workspaceChoices, pendingSecret != nil {
                        Text("\(email) belongs to \(choices.count) workspaces. Choose one to open.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(choices) { choice in
                            Button { signIn(choice.id) } label: {
                                HStack(spacing: 9) {
                                    WorkspaceMonogram(name: choice.name, size: 22)
                                    Text(choice.name)
                                    Spacer()
                                    Text(choice.roleTitle).foregroundStyle(.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        HStack {
                            if session.isBusy { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("Cancel") { pendingSecret = nil; session.cancelWorkspaceChoice() }
                        }
                    } else {
                        TextField("Server", text: $session.baseURL, prompt: Text("https://mail.example.com"))
                            .textContentType(.URL).autocorrectionDisabled()
                        TextField("Email", text: $email).textContentType(.username).autocorrectionDisabled()
                        SecureField("Password", text: $password).textContentType(.password)
                        HStack {
                            if session.isBusy { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("Sign In") {
                                pendingSecret = password
                                password = ""
                                signIn(nil)
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(session.isBusy || email.isEmpty || password.isEmpty || session.baseURL.isEmpty)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    statusMessages
                }
            }
            if !store.previousAccountDrafts.isEmpty {
                Section {
                    ForEach(store.previousAccountDrafts) { draft in
                        previousDraftRow(draft)
                    }
                } header: {
                    Text("Earlier drafts")
                } footer: {
                    Text("Choose a connected account in From before sending. If a send was attempted, check Sent first.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: connection.cancel)
        .onDisappear { pendingSecret = nil }
        .sheet(item: $renaming) { account in
            AccountNamingSheet(account: account, session: session)
        }
        .sheet(item: $connection.newAccount) { account in
            AccountNamingSheet(account: account, session: session, isNew: true)
        }
        .confirmationDialog("Disconnect mail account?", isPresented: Binding(
            get: { accountToDisconnect != nil },
            set: { if !$0 { accountToDisconnect = nil } }
        ), titleVisibility: .visible) {
            if let account = accountToDisconnect {
                Button("Disconnect \(account.name ?? account.email)", role: .destructive) { disconnect(account) }
            }
            Button("Cancel", role: .cancel) { accountToDisconnect = nil }
        } message: {
            Text("Syncing stops and pending sends are cancelled. Mail and drafts on this Mac stay.")
        }
    }

    @ViewBuilder private var statusMessages: some View {
        if let error = session.errorMessage {
            Text(error).font(.system(size: 11.5)).foregroundStyle(.red).textSelection(.enabled)
        }
        if let message = session.statusMessage {
            Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func previousDraftRow(_ draft: MailMessage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PostmereIcon("doc", size: 18).foregroundStyle(PostmereTheme.icon)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(MailMessage.displaySubject(draft.subject))
                    .lineLimit(2)
                Text(draft.providerAccountEmail ?? draft.senderEmail)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let error = store.outgoingQueue.first(where: { $0.id == draft.id })?.lastError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Review") {
                store.reviewPreviousAccountDraft(id: draft.id)
                if store.isComposing { openWindow(id: "compose") }
            }.disabled(store.isComposing)
        }.padding(.vertical, 3)
    }

    private func accountRow(_ account: BackendAccount) -> some View {
        let google = account.provider == "gmail"
        let connected = account.status == "connected"
        let synced = account.lastSyncedAt.map { "synced \($0.formatted(.relative(presentation: .named)))" }
        return HStack(spacing: 11) {
            BrandTile(brand: google ? .gmail : .outlook, size: 24)
                .opacity(connected ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name ?? account.email).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text([account.name == nil ? nil : account.email, google ? "Google" : "Outlook", connected ? synced : "needs reconnecting"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1).truncationMode(.middle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(connected ? Color.secondary : SettingsTint.orange)
            }
            Spacer(minLength: 8)
            if disconnectingAccountID == account.id {
                ProgressView().controlSize(.small)
            } else if !connected {
                Button("Reconnect") { connect(account.provider, reconnecting: account) }
                    .controlSize(.small)
                    .disabled(isManagingAccounts)
            }
            Menu {
                Button(account.name == nil ? "Name Account…" : "Rename…") { renaming = account }
                Button("Reconnect…") { connect(account.provider, reconnecting: account) }
                Divider()
                Button("Disconnect…", role: .destructive) { accountToDisconnect = account }
            } label: {
                PostmereIcon("ellipsis", size: 15).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isManagingAccounts)
            .help("Manage \(account.email)")
            .accessibilityLabel("Manage \(account.email)")
        }
        .padding(.vertical, 1)
    }

    /// Signs in, then once more with the chosen workspace when the person is in several.
    private func signIn(_ workspaceID: UUID?) {
        guard let secret = pendingSecret, !session.isBusy else { return }
        Task {
            await session.login(email: email, password: secret, workspaceID: workspaceID)
            if session.workspaceChoices == nil || session.isConnected { pendingSecret = nil }
            if session.isConnected { await onSync() }
        }
    }

    private func connect(_ provider: String, reconnecting account: BackendAccount? = nil) {
        guard !isManagingAccounts else { return }
        connection.start(provider, session: session, reconnecting: account,
                         calendarAccess: calendarAccess) { await onSync() }
    }

    private func disconnect(_ account: BackendAccount) {
        guard !isManagingAccounts else { return }
        accountToDisconnect = nil
        disconnectingAccountID = account.id
        Task {
            defer { disconnectingAccountID = nil }
            do {
                try await session.disconnectAccount(id: account.id)
                await onSync()
            } catch { session.errorMessage = error.localizedDescription }
        }
    }
}
