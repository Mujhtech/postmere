import SwiftUI

struct BackendConnectionView: View {
    @Bindable var session: BackendSession
    @Bindable var store: MailStore
    @Environment(\.openWindow) private var openWindow
    var onSync: @MainActor @Sendable () async -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var workspaceID = ""
    @State private var connection = MailAccountConnection()
    @State private var calendarAccess = false
    @State private var accountToDisconnect: BackendAccount?
    @State private var disconnectingAccountID: UUID?

    private var isManagingAccounts: Bool {
        session.isBusy || connection.provider != nil || disconnectingAccountID != nil
    }

    var body: some View {
        Form {
            Section("Postmere workspace") {
                if session.isConnected {
                    LabeledContent("Server", value: session.baseURL)
                    Text("Your workspace keeps your accounts in sync and delivers scheduled mail while this Mac is asleep.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let serverURL = URL(string: session.baseURL) {
                        Link("Manage connected assistants", destination: serverURL.appending(path: "mcp/connected"))
                    }
                    Text("Signing out also revokes this workspace’s assistant connections.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Sync Mail") { Task { await onSync() } }
                            .disabled(isManagingAccounts || session.accounts.isEmpty)
                        Spacer()
                        Button("Sign Out") { Task { await session.logout() } }
                            .disabled(isManagingAccounts)
                    }
                } else {
                    TextField("Server", text: $session.baseURL, prompt: Text("https://mail.example.com"))
                        .textContentType(.URL).autocorrectionDisabled()
                    TextField("Workspace ID", text: $workspaceID).autocorrectionDisabled()
                    TextField("Email", text: $email).textContentType(.username).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    HStack {
                        Text("Use the workspace details supplied by your administrator.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign In") {
                            let secret = password
                            password = ""
                            Task {
                                await session.login(email: email, password: secret, workspaceID: workspaceID)
                                if session.isConnected { await onSync() }
                            }
                        }
                        .disabled(session.isBusy || email.isEmpty || password.isEmpty || workspaceID.isEmpty || session.baseURL.isEmpty)
                        .buttonStyle(.borderedProminent)
                    }
                }
                if session.isBusy { ProgressView().controlSize(.small) }
                if let error = session.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let message = session.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if session.isConnected {
                Section("Mail accounts") {
                    ForEach(session.accounts) { account in
                        accountRow(account)
                    }
                    if session.accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No email accounts yet").font(.headline)
                            Text("Add your Google or Outlook accounts to start reading and sending mail.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                    HStack {
                        Button("Add Google") { connect("gmail") }
                        Button("Add Outlook") { connect("microsoft") }
                    }.disabled(isManagingAccounts)
                    Text("Add multiple accounts from either provider. Each account keeps its own inbox and sending address.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Include calendar access for booking and RSVP", isOn: $calendarAccess)
                        .font(.system(size: 12))
                        .disabled(isManagingAccounts)
                    Text("To add calendar access later, turn this on and reconnect the account.")
                        .font(.caption).foregroundStyle(.secondary)
                    if connection.provider != nil {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(connection.reconnectingEmail.map { "Sign in as \($0) in your browser." }
                                 ?? "Finish signing in in your browser.")
                                .font(.caption)
                            Spacer()
                            Button("Cancel", action: connection.cancel)
                        }
                    }
                }
            }
            if !store.previousAccountDrafts.isEmpty {
                Section("Previous local drafts") {
                    Text("Review these saved drafts, then choose a connected workspace account in From. For any previously attempted delivery, check Sent before sending again.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(store.previousAccountDrafts) { draft in
                        previousDraftRow(draft)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: connection.cancel)
        .confirmationDialog("Disconnect mail account?", isPresented: Binding(
            get: { accountToDisconnect != nil },
            set: { if !$0 { accountToDisconnect = nil } }
        ), titleVisibility: .visible) {
            if let account = accountToDisconnect {
                Button("Disconnect \(account.email)", role: .destructive) { disconnect(account) }
            }
            Button("Cancel", role: .cancel) { accountToDisconnect = nil }
        } message: {
            Text("This stops syncing the account and cancels its pending sends. Existing mail and drafts on this Mac stay saved.")
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
            Button("Review Draft") {
                store.reviewPreviousAccountDraft(id: draft.id)
                if store.isComposing { openWindow(id: "compose") }
            }.disabled(store.isComposing)
        }.padding(.vertical, 3)
    }

    private func accountRow(_ account: BackendAccount) -> some View {
        HStack(spacing: 12) {
            PostmereIcon("envelope", size: 19).foregroundStyle(PostmereTheme.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.email).lineLimit(1).truncationMode(.middle)
                Text("\(account.provider == "gmail" ? "Google" : "Microsoft Outlook")\(account.status == "connected" ? "" : " · Reconnect required")")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = account.lastSyncedAt {
                    Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if disconnectingAccountID == account.id {
                ProgressView().controlSize(.small)
            } else if account.status != "connected" {
                Button("Reconnect") { connect(account.provider, reconnecting: account) }
                    .disabled(isManagingAccounts)
            }
            Menu {
                Button("Reconnect…") { connect(account.provider, reconnecting: account) }
                Button("Disconnect…", role: .destructive) { accountToDisconnect = account }
            } label: {
                PostmereIcon("ellipsis", size: 16).foregroundStyle(PostmereTheme.icon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isManagingAccounts)
            .help("Manage \(account.email)")
            .accessibilityLabel("Manage \(account.email)")
        }.padding(.vertical, 3)
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
