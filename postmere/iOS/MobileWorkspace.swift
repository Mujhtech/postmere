import SwiftUI

// MARK: - Shared conversations

/// Conversations teammates shared with you, and the ones you shared.
struct MobileSharedThreadsScreen: View {
    let runtime: MailRuntime
    @State private var threads: [SharedThread] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            ForEach(threads) { thread in
                NavigationLink {
                    MobileSharedThreadView(runtime: runtime, threadID: thread.id)
                } label: {
                    HStack(spacing: 12) {
                        ParticipantPhoto(address: thread.ownerEmail, name: "", size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MailMessage.displaySubject(thread.subject))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(thread.ownerId == runtime.backend.credential?.userID ? "Shared by you" : thread.ownerEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(thread.updatedAt.mobileListDate).font(.caption2).foregroundStyle(.tertiary)
                            permissionBadge(thread.permission)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .overlay {
            if loaded && threads.isEmpty && error == nil {
                MobileEmptyState(symbol: "bubble.left.and.bubble.right", title: "Nothing shared yet",
                                 message: "To share a conversation, open it and choose Share with Team from the ••• menu.")
            } else if !loaded {
                ProgressView()
            }
        }
        .navigationTitle("Shared with Team")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func permissionBadge(_ permission: String) -> some View {
        Text(MobileSharedThreadView.permissionTitle(permission))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Mobile.raised, in: Capsule())
    }

    private func reload() async {
        do {
            let response: SharedThreads = try await runtime.backend.request("GET", "/v1/shared/threads")
            withAnimation(.snappy) { threads = response.threads.sorted { $0.updatedAt > $1.updatedAt } }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// A shared snapshot: the messages, then the team's discussion, chat style.
struct MobileSharedThreadView: View {
    let runtime: MailRuntime
    let threadID: UUID
    @Environment(\.postmereAccent) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var detail: SharedThreadDetail?
    @State private var older: [SharedComment] = []
    @State private var nextBefore: UUID?
    @State private var comment = ""
    @State private var posting = false
    @State private var error: String?
    @State private var confirmsRevoke = false
    @State private var expanded: Set<UUID> = []
    @FocusState private var commentFocused: Bool

    static func permissionTitle(_ permission: String) -> String {
        switch permission {
        case "owner": "Owner"
        case "comment": "Can comment"
        default: "View only"
        }
    }

    private var me: UUID? { runtime.backend.credential?.userID }

    var body: some View {
        Group {
            if let detail {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            header(detail)
                            ForEach(detail.messages) { message in
                                MobileHairline()
                                messageView(message, isLast: message.id == detail.messages.last?.id)
                            }
                            MobileHairline()
                            discussion(detail)
                                .id("discussion")
                        }
                        .padding(.bottom, 20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: detail.comments.count) { withAnimation(.snappy) { proxy.scrollTo("discussion", anchor: .bottom) } }
                }
                .safeAreaInset(edge: .bottom) {
                    if detail.thread.permission != "view" { commentBar }
                }
                .toolbar { toolbar(detail) }
            } else if let error {
                MobileEmptyState(symbol: "exclamationmark.bubble", title: "Can’t open this share", message: error)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Shared")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Comments from teammates arrive while you read.
            while !Task.isCancelled {
                await reload()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
        .confirmationDialog("Stop sharing this conversation?", isPresented: $confirmsRevoke, titleVisibility: .visible) {
            Button("Stop Sharing", role: .destructive) { Task { await revoke() } }
        } message: {
            Text("Teammates lose access to the snapshot and the discussion. Your own mail is kept.")
        }
    }

    private func header(_ detail: SharedThreadDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MailMessage.displaySubject(detail.thread.subject))
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Label(detail.thread.ownerId == me ? "Shared by you" : detail.thread.ownerEmail, systemImage: "person.2.fill")
                Text("·")
                Text(Self.permissionTitle(detail.thread.permission))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if !detail.members.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: -8) {
                        ForEach(detail.members) { member in
                            ParticipantPhoto(address: member.email, name: "", size: 28)
                                .overlay { Circle().strokeBorder(Mobile.background, lineWidth: 2) }
                        }
                    }
                }
                .accessibilityLabel("Shared with " + detail.members.map(\.email).joined(separator: ", "))
            }
        }
        .padding(.horizontal, Mobile.gutter)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private func messageView(_ message: BackendMailMessage, isLast: Bool) -> some View {
        let open = isLast || expanded.contains(message.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    if expanded.contains(message.id) { expanded.remove(message.id) } else { expanded.insert(message.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    ParticipantPhoto(address: message.from.email, name: message.from.name ?? "", size: open ? 36 : 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(message.from.name ?? message.from.email)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(open ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(message.sentAt.mobileListDate).font(Mobile.meta).foregroundStyle(.tertiary)
                        }
                        if !open {
                            Text(message.preview).font(Mobile.rowLine).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(message.textBody)
                    .font(.system(size: 16))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.attachments) { attachment in
                            Label(attachment.filename, systemImage: "paperclip")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("Attachment names only; contents stay private.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, Mobile.gutter)
        .padding(.vertical, open ? 16 : 12)
    }

    private func discussion(_ detail: SharedThreadDetail) -> some View {
        let comments = (older + detail.comments).sorted { $0.createdAt < $1.createdAt }
        let composing = detail.presence.filter { $0.userId != me && $0.expiresAt > .now }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Discussion").font(.headline)
                Spacer()
                if nextBefore != nil {
                    Button("Earlier comments") { Task { await loadOlder() } }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.accent)
                }
            }
            if comments.isEmpty {
                Text(detail.thread.permission == "view" ? "No comments yet." : "No comments yet. Start the conversation below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(comments) { item in bubble(item, detail: detail) }
            if !composing.isEmpty {
                Label(composing.map(\.email).joined(separator: ", ") + " is writing a reply", systemImage: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.horizontal, Mobile.gutter)
        .padding(.top, 16)
    }

    private func bubble(_ item: SharedComment, detail: SharedThreadDetail) -> some View {
        let mine = item.authorId == me
        return HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 48) } else {
                ParticipantPhoto(address: item.authorEmail, name: "", size: 26)
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine {
                    Text(item.authorEmail).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(item.body)
                    .font(.subheadline)
                    .foregroundStyle(mine ? .white : .primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(mine ? AnyShapeStyle(palette.accent) : AnyShapeStyle(Mobile.raised),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.body }
                if mine || detail.thread.permission == "owner" {
                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await deleteComment(item.id) } }
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
    }

    private var commentBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Comment for the team", text: $comment, axis: .vertical)
                .lineLimit(1...5)
                .focused($commentFocused)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            let empty = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                Task { await postComment() }
            } label: {
                Group {
                    if posting { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)) }
                }
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(empty ? Color.secondary.opacity(0.4) : palette.accent).interactive(), in: Circle())
            .disabled(empty || posting)
            .accessibilityLabel("Post comment")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ToolbarContentBuilder private func toolbar(_ detail: SharedThreadDetail) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                if detail.thread.permission != "view" && !RemoteAccountRegistry.accounts.isEmpty {
                    Menu("Reply from…", systemImage: "arrowshape.turn.up.left") {
                        ForEach(RemoteAccountRegistry.accounts, id: \.localID) { identity in
                            Button(identity.email) { reply(identity: identity, detail: detail) }
                        }
                    }
                    .disabled(runtime.store.isComposing || runtime.store.draftRecoveryAvailable)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                if detail.thread.permission == "owner" {
                    Button("Publish Latest Messages", systemImage: "arrow.triangle.2.circlepath") { Task { await publishLatest() } }
                    Button("Stop Sharing", systemImage: "person.2.slash", role: .destructive) { confirmsRevoke = true }
                }
            }
        }
    }

    private func reload() async {
        do {
            let next: SharedThreadDetail = try await runtime.backend.request("GET", "/v1/shared/threads/\(threadID.uuidString)")
            if detail == nil { nextBefore = next.commentsNextBefore }
            withAnimation(.snappy) { detail = next }
            error = nil
        } catch {
            if detail == nil { self.error = error.localizedDescription }
        }
    }

    private func postComment() async {
        posting = true
        defer { posting = false }
        do {
            let _: SharedComment = try await runtime.backend.request(
                "POST", "/v1/shared/threads/\(threadID.uuidString)/comments", body: SharedCommentInput(body: comment))
            comment = ""
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteComment(_ id: UUID) async {
        do {
            let _: BackendEmpty = try await runtime.backend.request(
                "DELETE", "/v1/shared/threads/\(threadID.uuidString)/comments/\(id.uuidString)")
            older.removeAll { $0.id == id }
            await reload()
        } catch {}
    }

    private func loadOlder() async {
        guard let nextBefore else { return }
        do {
            let page: SharedCommentPage = try await runtime.backend.request(
                "GET", "/v1/shared/threads/\(threadID.uuidString)/comments",
                query: [URLQueryItem(name: "before", value: nextBefore.uuidString)])
            let known = Set((older + (detail?.comments ?? [])).map(\.id))
            withAnimation(.snappy) { older += page.comments.filter { !known.contains($0.id) } }
            self.nextBefore = page.nextBefore
        } catch {}
    }

    private func publishLatest() async {
        guard let detail else { return }
        do {
            let _: SharedThread = try await runtime.backend.request(
                "POST", "/v1/shared/threads/\(threadID.uuidString)/refresh",
                body: SharedVersionInput(expectedVersion: detail.thread.version))
            await reload()
        } catch {}
    }

    private func revoke() async {
        do {
            let _: BackendEmpty = try await runtime.backend.request("DELETE", "/v1/shared/threads/\(threadID.uuidString)")
            dismiss()
        } catch {}
    }

    private func reply(identity: RemoteAccountIdentity, detail: SharedThreadDetail) {
        guard !runtime.store.isComposing, !runtime.store.draftRecoveryAvailable,
              let account = MailAccount(rawValue: identity.localID), let last = detail.messages.last else { return }
        let store = runtime.store
        store.beginCompose(account: account)
        store.draftTo = last.mailbox == "sent"
            ? last.to.map(\.email).filter { $0.caseInsensitiveCompare(identity.email) != .orderedSame }.joined(separator: ", ")
            : last.from.email
        store.draftSubject = last.subject.lowercased().hasPrefix("re:") ? last.subject : "Re: " + last.subject
        store.draftInReplyTo = last.rfcMessageId
        store.draftReferences = (last.references ?? []) + [last.rfcMessageId].compactMap { $0 }
        runtime.activeSharedReplyID = threadID
        runtime.activeSharedReplyScope = runtime.backend.scope
        Task { await runtime.refreshSharedPresence(force: true) }
    }
}

// MARK: - Members

/// Who's in the workspace; owners and admins can add or remove people.
struct MobileMembersSettings: View {
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
            Section {
                ForEach(members) { member in
                    HStack(spacing: 12) {
                        ParticipantPhoto(address: member.email, name: "", size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.email).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(member.userId == session.credential?.userID ? "\(member.role.capitalized) · You" : member.role.capitalized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if ownRole != "member", member.role != "owner", member.userId != session.credential?.userID {
                            Button("Remove", role: .destructive) { revoking = member }
                        }
                    }
                }
            } header: {
                Text("\(members.count) member\(members.count == 1 ? "" : "s")")
            } footer: {
                if ownRole != "member" && members.count > 1 { Text("Swipe left on someone to remove them.") }
            }
            if ownRole != "member" {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("First password (12+ characters)", text: $password)
                    Picker("Role", selection: $role) {
                        Text("Member").tag("member")
                        if ownRole == "owner" { Text("Administrator").tag("admin") }
                    }
                    Button {
                        Task { await create() }
                    } label: {
                        HStack { Text("Add Member"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(busy || password.utf8.count < 12 || MailAddressList(email).addresses.count != 1)
                } header: {
                    Text("Add someone")
                } footer: {
                    Text("No invitation email is sent. Give them the first password yourself, somewhere private.")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(PostmereTheme.destructiveInk) }
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Remove from workspace?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { member in
            Button("Remove \(member.email)", role: .destructive) { Task { await revoke(member) } }
        } message: { _ in
            Text("They’re signed out everywhere and lose access to everything shared in this workspace.")
        }
    }

    private func load() async {
        do {
            let response: WorkspaceMembers = try await session.request("GET", "/v1/workspace/members")
            withAnimation(.snappy) { members = response.members }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        busy = true
        error = nil
        let secret = password
        password = ""
        defer { busy = false }
        do {
            let _: WorkspaceMember = try await session.request(
                "POST", "/v1/workspace/members", body: WorkspaceMemberInput(email: email, initialPassword: secret, role: role))
            email = ""
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ member: WorkspaceMember) async {
        do {
            let _: BackendEmpty = try await session.request("DELETE", "/v1/workspace/members/\(member.userId.uuidString)")
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
