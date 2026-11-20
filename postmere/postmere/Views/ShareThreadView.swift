import SwiftUI

struct ShareThreadView: View {
    let runtime: MailRuntime
    var message: MailMessage?
    var existing: SharedThreadDetail?
    @Environment(\.dismiss) private var dismiss
    @State private var members: [WorkspaceMember] = []
    @State private var permissions: [UUID: String] = [:]
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(existing == nil ? "Share conversation" : "Manage access").font(PostmereTheme.sheetTitle)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(existing.map { MailMessage.displaySubject($0.thread.subject) } ?? message?.displaySubject ?? "Conversation").font(.headline).lineLimit(2)
            Text("Shares a snapshot of the synced conversation with the people you select. Bcc recipients and file contents are excluded. Publish an updated snapshot to include later messages.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if members.isEmpty { Text("No other workspace members yet.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(members) { member in
                        HStack {
                            Text(member.email).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            Picker("Access for \(member.email)", selection: Binding(get: { permissions[member.userId] ?? "none" }, set: { permissions[member.userId] = $0 })) {
                                Text("No access").tag("none")
                                Text("View").tag("view")
                                Text("Comment & reply").tag("comment")
                            }.labelsHidden().frame(width: 170)
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(existing == nil ? "Share Snapshot" : "Save Access") { Task { await save() } }
                    .buttonStyle(.borderedProminent).disabled(busy || (existing == nil && !permissions.values.contains(where: { $0 != "none" })))
            }
            .padding(.horizontal, dismissReaderPanel == nil ? 24 : 16).padding(.vertical, 10)
        }
        .frame(width: dismissReaderPanel == nil ? 590 : nil, height: dismissReaderPanel == nil ? 470 : nil)
        .mailPanelSurface(isPresented: dismissReaderPanel == nil)
        .task(id: LoadRequest(scope: runtime.backend.scope, revision: reload)) { await loadMembers() }
    }

    @ViewBuilder private var memberPermissions: some View {
        if !runtime.backend.isConnected {
            Text("Connect your workspace to manage sharing.").foregroundStyle(.secondary)
            AccountSettingsButton(title: "Open Accounts Settings…")
        } else if let members, loadedScope == runtime.backend.scope {
            if members.isEmpty {
                Text("No other workspace members yet.").foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(members) { member in
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Text(member.email).fixedSize()
                                Spacer(minLength: 0)
                                permissionPicker(for: member).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(member.email).lineLimit(1).truncationMode(.middle).help(member.email)
                                permissionPicker(for: member)
                            }
                        }
                    }
                }
                .disabled(saving)
            }
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        let selected = members.compactMap { member -> SharedMemberInput? in
            guard let permission = permissions[member.userId], permission != "none" else { return nil }
            return SharedMemberInput(userId: member.userId, permission: permission)
        }
        do {
            if let existing {
                let _: SharedThread = try await runtime.backend.request("PUT", "/v1/shared/threads/\(existing.thread.id.uuidString)/members", body: SharedMembersUpdate(members: selected, expectedVersion: existing.thread.version))
            } else {
                guard let message, let identity = message.mailAccount.remote, identity.scope == runtime.backend.scope,
                      let thread = message.providerThreadID else { throw BackendError.notConnected }
                let _: SharedThread = try await runtime.backend.request("POST", "/v1/shared/threads", body: ShareThreadInput(accountId: identity.accountID, providerThreadId: thread, members: selected))
            }
            runtime.store.lastAction = "Shared conversation access saved"
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
