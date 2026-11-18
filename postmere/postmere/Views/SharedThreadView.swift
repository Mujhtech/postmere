import SwiftUI

struct SharedThreadView: View {
    let runtime: MailRuntime
    let threadID: UUID
    @State private var detail: SharedThreadDetail?
    @State private var comment = ""
    @State private var error: String?
    @State private var posting = false
    @State private var showsAccess = false
    @State private var confirmsRevoke = false
    @State private var olderComments: [SharedComment] = []
    @State private var nextBefore: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(MailMessage.displaySubject(detail.thread.subject)).font(.system(size: 21, weight: .semibold, design: .serif))
                        HStack {
                            Text("Shared snapshot · \(detail.thread.ownerEmail)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Refresh Discussion") { Task { await reload() } }
                                if detail.thread.permission == "owner" {
                                    Button("Manage Access…") { showsAccess = true }
                                    Button("Publish Latest Messages") { Task { await publishLatest() } }
                                    Button("Revoke Share", role: .destructive) { confirmsRevoke = true }
                                }
                            } label: { PostmereIcon("ellipsis", size: 16) }.menuStyle(.borderlessButton).fixedSize()
                        }
                        ForEach(detail.messages) { message in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(message.from.name ?? message.from.email).font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text(message.sentAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(message.textBody).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if !message.attachments.isEmpty {
                                    Text("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s") · metadata only")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(message.attachments) { Text($0.filename).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(PostmereTheme.subtleFill, in: .rect(cornerRadius: PostmereTheme.cardRadius))
                        }
                        if detail.thread.permission != "view" {
                            Menu("Compose Reply from My Account") {
                                ForEach(RemoteAccountRegistry.accounts, id: \.localID) { identity in
                                    Button(identity.email) { reply(identity: identity, detail: detail) }
                                }
                            }.disabled(runtime.store.isComposing || runtime.store.draftRecoveryAvailable || RemoteAccountRegistry.accounts.isEmpty)
                        }
                        let present = detail.presence.filter { $0.userId != runtime.backend.credential?.userID && $0.expiresAt > .now }
                        if !present.isEmpty {
                            PostmereLabel(present.map(\.email).joined(separator: ", ") + " composing a reply", symbol: "square.and.pencil", size: 13)
                                .font(.caption).foregroundStyle(PostmereTheme.accentInk)
                        }
                        Divider()
                        Text("Discussion").font(.subheadline.weight(.semibold))
                        if nextBefore != nil { Button("Load Earlier Comments") { Task { await loadOlder() } }.font(.caption) }
                        ForEach((olderComments + detail.comments).sorted { $0.createdAt < $1.createdAt }) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.authorEmail).font(.caption.weight(.medium))
                                    Spacer()
                                    Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                    if item.authorId == runtime.backend.credential?.userID || detail.thread.permission == "owner" {
                                        Button { Task { await deleteComment(item.id) } } label: { PostmereIcon("trash", size: 11) }
                                            .buttonStyle(.borderless).help("Remove comment")
                                    }
                                }
                                Text(item.body).font(.system(size: 13)).textSelection(.enabled)
                            }.padding(.vertical, 4)
                        }
                        if detail.comments.isEmpty { Text("No comments yet.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(20)
                }.scrollIndicators(.never)
                if detail.thread.permission != "view" {
                    Divider()
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("Comment for shared participants", text: $comment, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                        Button("Post") { Task { await postComment() } }.disabled(posting || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(16)
                }
            } else if error == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(16) }
        }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            .task {
                while !Task.isCancelled {
                    await reload()
                    do { try await Task.sleep(for: .seconds(10)) } catch { break }
                }
            }
            .sheet(isPresented: $showsAccess) { if let detail { ShareThreadView(runtime: runtime, existing: detail) } }
            .confirmationDialog("Revoke this shared snapshot?", isPresented: $confirmsRevoke, titleVisibility: .visible) {
                Button("Revoke Share", role: .destructive) { Task { await revoke() } }
            } message: { Text("Participants will lose access to the snapshot and discussion. Your original mail is kept.") }
    }

    private func reload() async {
        do {
            let next: SharedThreadDetail = try await runtime.backend.request("GET", "/v1/shared/threads/\(threadID.uuidString)")
            if detail == nil { nextBefore = next.commentsNextBefore }
            detail = next; error = nil
        } catch { self.error = error.localizedDescription; detail = nil; olderComments = [] }
    }
    private func postComment() async {
        posting = true; defer { posting = false }
        do {
            let _: SharedComment = try await runtime.backend.request("POST", "/v1/shared/threads/\(threadID.uuidString)/comments", body: SharedCommentInput(body: comment))
            comment = ""; await reload()
        } catch { self.error = error.localizedDescription }
    }
    private func deleteComment(_ id: UUID) async {
        do { let _: BackendEmpty = try await runtime.backend.request("DELETE", "/v1/shared/threads/\(threadID.uuidString)/comments/\(id.uuidString)"); olderComments.removeAll { $0.id == id }; await reload() }
        catch { self.error = error.localizedDescription }
    }
    private func loadOlder() async {
        guard let nextBefore else { return }
        do {
            let page: SharedCommentPage = try await runtime.backend.request("GET", "/v1/shared/threads/\(threadID.uuidString)/comments", query: [URLQueryItem(name: "before", value: nextBefore.uuidString)])
            let known = Set((olderComments + (detail?.comments ?? [])).map(\.id))
            olderComments += page.comments.filter { !known.contains($0.id) }
            self.nextBefore = page.nextBefore
        } catch { self.error = error.localizedDescription }
    }
    private func publishLatest() async {
        guard let detail else { return }
        do { let _: SharedThread = try await runtime.backend.request("POST", "/v1/shared/threads/\(threadID.uuidString)/refresh", body: SharedVersionInput(expectedVersion: detail.thread.version)); await reload() }
        catch { self.error = error.localizedDescription }
    }
    private func revoke() async {
        do { let _: BackendEmpty = try await runtime.backend.request("DELETE", "/v1/shared/threads/\(threadID.uuidString)"); detail = nil; error = "This share was revoked." }
        catch { self.error = error.localizedDescription }
    }
    private func reply(identity: RemoteAccountIdentity, detail: SharedThreadDetail) {
        guard !runtime.store.isComposing, !runtime.store.draftRecoveryAvailable,
              let account = MailAccount(rawValue: identity.localID), let last = detail.messages.last else { return }
        runtime.store.beginCompose(account: account)
        runtime.store.draftTo = last.mailbox == "sent"
            ? last.to.map(\.email).filter { $0.caseInsensitiveCompare(identity.email) != .orderedSame }.joined(separator: ", ")
            : last.from.email
        runtime.store.draftSubject = last.subject.lowercased().hasPrefix("re:") ? last.subject : "Re: " + last.subject
        runtime.store.draftInReplyTo = last.rfcMessageId
        runtime.store.draftReferences = (last.references ?? []) + [last.rfcMessageId].compactMap { $0 }
        runtime.activeSharedReplyID = threadID
        runtime.activeSharedReplyScope = runtime.backend.scope
        Task { await runtime.refreshSharedPresence(force: true) }
    }
}

extension BackendMailMessage: Identifiable {}
