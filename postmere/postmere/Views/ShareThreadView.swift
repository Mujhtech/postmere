import SwiftUI

struct ShareThreadView: View {
    let runtime: MailRuntime
    var message: MailMessage?
    var existing: SharedThreadDetail?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissReaderPanel) private var dismissReaderPanel
    @State private var members: [WorkspaceMember]?
    @State private var loadedScope: String?
    @State private var permissions: [UUID: String] = [:]
    @State private var reload = 0
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saving = false

    private struct LoadRequest: Equatable {
        let scope: String?
        let revision: Int
    }

    private var canSave: Bool {
        members != nil && runtime.backend.isConnected && loadedScope == runtime.backend.scope && !saving
            && (existing != nil || permissions.values.contains { $0 != "none" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dismissReaderPanel == nil {
                HStack {
                    Text(existing == nil ? "Share conversation" : "Manage access").font(PostmereTheme.sheetTitle)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24).padding(.top, 24)
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(existing.map { MailMessage.displaySubject($0.thread.subject) } ?? message?.displaySubject ?? "Conversation")
                            .font(.headline).lineLimit(2)
                        Text("Share a snapshot with workspace members. Bcc recipients and attachment contents stay private. Publish again to include later messages.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        memberPermissions
                        if let saveError {
                            Text(saveError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                                .id("share-error")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(dismissReaderPanel == nil ? 24 : 16)
                }
                .onChange(of: saveError) { _, error in
                    if error != nil { reader.scrollTo("share-error", anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small).accessibilityLabel("Saving access") }
                Spacer()
                Button(existing == nil ? "Share Snapshot" : "Save Access") { Task { await save() } }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
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
        } else if let loadError {
            Text(loadError).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Retry") { reload += 1 }
        } else {
            ProgressView("Loading workspace members…").controlSize(.small)
        }
    }

    private func permissionPicker(for member: WorkspaceMember) -> some View {
        Picker("Access for \(member.email)", selection: Binding(
            get: { permissions[member.userId] ?? "none" },
            set: { permissions[member.userId] = $0 }
        )) {
            Text("No access").tag("none")
            Text("View").tag("view")
            Text("Comment & reply").tag("comment")
        }
        .labelsHidden()
    }

    private func loadMembers() async {
        members = nil
        loadedScope = nil
        permissions = [:]
        loadError = nil
        saveError = nil
        guard let scope = runtime.backend.scope else { return }
        do {
            let response: WorkspaceMembers = try await runtime.backend.request("GET", "/v1/workspace/members")
            guard !Task.isCancelled, runtime.backend.scope == scope else { return }
            members = response.members.filter { $0.userId != runtime.backend.credential?.userID }
            if let existing { permissions = Dictionary(uniqueKeysWithValues: existing.members.map { ($0.userId, $0.permission) }) }
            loadedScope = scope
        } catch {
            if !Task.isCancelled, runtime.backend.scope == scope { loadError = error.localizedDescription }
        }
    }

    private func save() async {
        guard canSave, let members else { return }
        saving = true
        saveError = nil
        defer { saving = false }
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
            if let dismissReaderPanel { dismissReaderPanel() } else { dismiss() }
        } catch { saveError = error.localizedDescription }
    }
}
