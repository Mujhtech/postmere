import SwiftUI

struct WorkspaceView: View {
    let runtime: MailRuntime
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            PostmereSheetHeader("Workspace")
            if runtime.backend.isConnected {
                Picker("Workspace", selection: $tab) {
                    Text("Shared threads").tag(0); Text("Team templates").tag(1); Text("Members").tag(2)
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 22).padding(.bottom, 18)
                Divider()
                if tab == 0 { SharedThreadsView(runtime: runtime) }
                else if tab == 1 { SharedTemplatesView(runtime: runtime) }
                else { WorkspaceMembersView(session: runtime.backend) }
            } else {
                Divider()
                ContentUnavailableView {
                    PostmereLabel.emptyState("Connect your workspace", symbol: "bubble.left.and.bubble.right", size: 36)
                } description: { Text("Sign in to see shared conversations, team templates, and members.") } actions: {
                    AccountSettingsButton()
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 790, height: 670).tint(PostmereTheme.accent)
    }
}

private struct SharedThreadsView: View {
    let runtime: MailRuntime
    @State private var threads: [SharedThread] = []
    @State private var selected: UUID?
    @State private var error: String?
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack { Text("Conversations").font(.caption.weight(.medium)); Spacer(); Button { Task { await reload() } } label: { PostmereIcon("arrow.clockwise", size: 13) }.help("Refresh shared threads") }.padding(14)
                List(threads, selection: $selected) { thread in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(MailMessage.displaySubject(thread.subject)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(thread.ownerEmail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("\(thread.messageCount) messages · \(thread.permission)").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(thread.id)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding() }
            }.frame(minWidth: 210, idealWidth: 240, maxWidth: 290)
            if let selected { SharedThreadView(runtime: runtime, threadID: selected).id(selected) }
            else {
                ContentUnavailableView {
                    PostmereLabel.emptyState("Shared conversations", symbol: "bubble.left.and.bubble.right", size: 32)
                } description: { Text("Select a shared thread. To share your own, choose Share Conversation from its message menu.") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task { await reload() }
    }
    private func reload() async {
        do { let response: SharedThreads = try await runtime.backend.request("GET", "/v1/shared/threads"); threads = response.threads; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct WorkspaceMembersView: View {
    let session: BackendSession
    @State private var members: [WorkspaceMember] = []
    @State private var email = ""
    @State private var password = ""
    @State private var role = "member"
    @State private var busy = false
    @State private var error: String?
    @State private var revoking: WorkspaceMember?
    private var ownRole: String { members.first { $0.userId == session.credential?.userID }?.role ?? "member" }
    var body: some View {
        Form {
            Section("Members") {
                ForEach(members) { member in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(member.email); Text(member.role.capitalized).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if ownRole != "member", member.role != "owner", member.userId != session.credential?.userID {
                            Button("Revoke Access", role: .destructive) { revoking = member }.controlSize(.small)
                        }
                    }
                }
            }
            if ownRole != "member" {
                Section("Add member") {
                    TextField("Email", text: $email).autocorrectionDisabled()
                    SecureField("Initial password", text: $password)
                    Picker("Role", selection: $role) {
                        Text("Member").tag("member")
                        if ownRole == "owner" { Text("Administrator").tag("admin") }
                    }
                    Text("Creates access to this workspace. Share the initial password with the member through your secure channel. No invitation email is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Create Member") { Task { await createMember() } }.disabled(busy || password.utf8.count < 12 || MailAddressList(email).addresses.count != 1)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.formStyle(.grouped).task { await load() }
            .confirmationDialog("Revoke workspace access?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
                if let member = revoking {
                    Button("Revoke \(member.email)", role: .destructive) {
                        Task {
                            do { let _: BackendEmpty = try await session.request("DELETE", "/v1/workspace/members/\(member.userId.uuidString)"); await load() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            } message: { Text("Their sessions will end and they will lose access to this workspace’s shared content.") }
    }
    private func load() async { do { let response: WorkspaceMembers = try await session.request("GET", "/v1/workspace/members"); members = response.members } catch { self.error = error.localizedDescription } }
    private func createMember() async {
        busy = true; error = nil
        let secret = password; password = ""
        defer { busy = false }
        do {
            let _: WorkspaceMember = try await session.request("POST", "/v1/workspace/members", body: WorkspaceMemberInput(email: email, initialPassword: secret, role: role))
            email = ""; await load()
        } catch { self.error = error.localizedDescription }
    }
}
