import SwiftUI
import AppKit

struct BackendConnectionView: View {
    @Bindable var session: BackendSession
    var onSync: () async -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var workspaceID = ""
    @State private var connectingProvider: String?
    @State private var reconnectingEmail: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionID: UUID?
    @State private var calendarAccess = false
    @State private var accountToDisconnect: BackendAccount?
    @State private var disconnectingAccountID: UUID?

    private var isManagingAccounts: Bool {
        session.isBusy || connectingProvider != nil || disconnectingAccountID != nil
    }

    var body: some View {
        Form {
            Section("Postmere workspace") {
                if session.isConnected {
                    LabeledContent("Server", value: session.baseURL)
                    Text("Your workspace keeps your accounts in sync and delivers scheduled mail while this Mac is asleep.")
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
                    if connectingProvider != nil {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(reconnectingEmail.map { "Sign in as \($0) in your browser." }
                                 ?? "Finish signing in in your browser.")
                                .font(.caption)
                            Spacer()
                            Button("Cancel", action: cancelConnection)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
        .onDisappear(perform: cancelConnection)
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
        let id = UUID()
        connectionID = id
        session.errorMessage = nil
        connectingProvider = provider
        reconnectingEmail = account?.email
        let includeCalendar = calendarAccess || account?.capabilities?.contains("calendar") == true
        connectionTask = Task {
            defer {
                if connectionID == id {
                    connectingProvider = nil
                    reconnectingEmail = nil
                    connectionID = nil
                    connectionTask = nil
                }
            }
            do {
                let connection = try await session.startOAuth(provider: provider, calendarAccess: includeCalendar)
                try Task.checkCancellation()
                guard let url = URL(string: connection.authorizationUrl), url.scheme == "https",
                      ["accounts.google.com", "login.microsoftonline.com"].contains(url.host ?? ""),
                      url.user == nil, url.password == nil else { throw BackendError.invalidURL }
                guard NSWorkspace.shared.open(url) else { throw BackendError.invalidURL }
                try await session.waitForOAuth(connection, expectedAccountID: account?.id)
                try Task.checkCancellation()
                await onSync()
            } catch is CancellationError { }
            catch { if connectionID == id { session.errorMessage = error.localizedDescription } }
        }
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionID = nil
        connectingProvider = nil
        reconnectingEmail = nil
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
