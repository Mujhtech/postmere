import SwiftUI
import AppKit

struct ReaderView: View {
    @Bindable var store: MailStore
    @Environment(MailRuntime.self) private var runtime
    @AppStorage("readingFontSize") private var readingFontSize = 14.0
    @State private var presentedSheet: ReaderSheet?
    @State private var attachmentError: String?
    @State private var expandedMessageIDs: Set<UUID> = []
    @State private var loadingAttachmentID: UUID?

    private enum ReaderSheet: Identifiable {
        case messageDetails(MailMessage)
        case attachment(MailAttachment)
        case unsubscribe(MailMessage)
        case activity(MailMessage)
        case calendar(MailCalendarEventDraft)
        case invitation(MailCalendarInvitation, MailAccount)
        case sender(MailMessage)
        case ai(MailMessage, MailAIMode)
        case share(MailMessage)

        var id: String {
            switch self {
            case .messageDetails(let message): "details-\(message.id)"
            case .attachment(let attachment): "attachment-\(attachment.id)"
            case .unsubscribe(let message): "unsubscribe-\(message.id)"
            case .activity(let message): "activity-\(message.id)"
            case .calendar(let draft): "calendar-\(draft.id)"
            case .invitation(let invitation, _): "invitation-\(invitation.id)"
            case .sender(let message): "sender-\(message.id)"
            case .ai(let message, let mode): "ai-\(mode.rawValue)-\(message.id)"
            case .share(let message): "share-\(message.id)"
            }
        }
    }

    var body: some View {
        Group {
            if store.selectedMessageIDs.count > 1 {
                ContentUnavailableView {
                    PostmereLabel.emptyState("\(store.selectedMessageIDs.count) Messages Selected", symbol: "envelope.on.envelope", size: 40)
                } description: {
                    Text("Use the list actions or Message menu to organize your selection.")
                } actions: {
                    HStack {
                        Button("Archive", action: store.archiveSelected).disabled(!store.canMoveSelected(to: .archive))
                        Button("Move to Trash", action: store.deleteSelected).disabled(!store.canMoveSelected(to: .trash))
                    }
                }
            } else if let message = store.selectedMessage {
                let conversation = message.isDraft || message.mailbox == .outbox ? [message] : store.conversationMessages(for: message)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        readerHeading(message)
                            .padding(.bottom, conversation.count > 1 ? 10 : 16)
                        workflowSummary(message)
                        MailDateSuggestionsView(title: message.subject, text: message.paragraphs.joined(separator: "\n\n")) {
                            presentedSheet = .calendar($0)
                        }.padding(.bottom, 10)
                        if message.isOutgoing && message.mailbox == .sent {
                            HStack {
                                Button { presentedSheet = .activity(message) } label: {
                                    PostmereLabel("Message activity", symbol: "eye", size: 14)
                                }.buttonStyle(.borderless)
                                Spacer()
                                if message.trackOpens != true && message.trackLinks != true { Text("Tracking off").foregroundStyle(.secondary) }
                            }.font(.caption).padding(.bottom, 16)
                        }
                        if MailUnsubscribeService.options(for: message).isAvailable {
                            HStack(spacing: 9) {
                                PostmereIcon("envelope", size: 14).foregroundStyle(PostmereTheme.icon)
                                Text("Mailing list").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Unsubscribe…") { presentedSheet = .unsubscribe(message) }
                                    .buttonStyle(.borderless).font(.caption)
                            }.padding(.bottom, 16)
                        }
                        if conversation.count > 1 {
                            conversationSummary(conversation, selected: message)
                                .padding(.bottom, 20)
                            VStack(spacing: 12) {
                                ForEach(conversation) { entry in
                                    conversationMessage(entry)
                                }
                            }
                        } else {
                            senderHeader(message)
                            Divider().padding(.vertical, 18)
                            messageContents(message)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                }
                .id(message.id)
            } else {
                ContentUnavailableView {
                    PostmereLabel.emptyState("No Message Selected", symbol: "envelope", size: 40)
                } description: {
                    Text("Choose a message from the list, or write a new one.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PostmereTheme.paper)
        .toolbar { readerToolbar }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .messageDetails(let message): messageDetails(message)
            case .attachment(let attachment): AttachmentPreviewSheet(attachment: attachment)
            case .activity(let message): MessageActivityView(message: message, session: runtime.backend)
            case .share(let message): ShareThreadView(runtime: runtime, message: message)
            case .calendar(let draft): CalendarEventDraftView(draft: draft)
            case .invitation(let invitation, let account):
                CalendarInvitationSheet(invitation: invitation, session: runtime.backend, account: account)
            case .sender(let message):
                SenderContextView(store: store, email: message.senderEmail, accountKey: MailContactIdentity.accountKey(for: message), displayName: message.sender,
                    onOpenMessage: { selected in
                        presentedSheet = nil
                        store.selectAccount(selected.account)
                        store.selectedInboxSplitID = nil
                        store.selectedMailbox = selected.mailbox
                        store.select(selected)
                    }, onOpenAttachment: { attachment, source in resolveAttachment(attachment, message: source, save: false) })
            case .ai(let message, let mode):
                MailAIAssistantView(runtime: runtime, mode: mode, messages: store.conversationMessages(for: message))
            case .unsubscribe(let message):
                UnsubscribeView(message: message, onComposeEmail: { email in
                    guard !store.isComposing && !store.draftRecoveryAvailable else {
                        throw NSError(domain: "Postmere", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Save or close your current draft before preparing an unsubscribe email."])
                    }
                    store.beginCompose()
                    store.draftAccount = message.mailAccount
                    store.draftProviderAccountEmail = message.providerAccountEmail
                    store.draftTo = email.recipients.joined(separator: ", ")
                    store.draftSubject = email.subject
                    store.draftBody = email.body
                }, onLocalActions: { archive, block in
                    if archive { store.moveMessages([message.id], to: .archive) }
                    if block {
                        store.saveSenderRule(SenderRule(email: message.senderEmail, account: message.account,
                                                        route: .blocked, providerAccountEmail: message.providerAccountEmail),
                                             applyToExisting: false)
                        store.lastAction = archive ? "Message archived · future mail from sender blocked" : "Future mail from sender blocked"
                    }
                }, session: runtime.backend)
            }
        }
        .onChange(of: store.selectedMessageID, initial: true) {
            presentedSheet = nil
            expandedMessageIDs = Set([store.selectedMessageID].compactMap { $0 })
        }
        .alert("Unable to open attachment", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK") { attachmentError = nil }
        } message: { Text(attachmentError ?? "Please try again.") }
    }

    private func readerHeading(_ message: MailMessage) -> some View {
        let subject = Text(message.displaySubject)
            .font(.system(size: 24, weight: .semibold, design: .serif))
            .tracking(-0.4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        return Group {
            if showsQuickActions(for: message) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        subject.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        quickActions(message)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        subject
                        quickActions(message)
                    }
                }
            } else {
                subject
            }
        }
    }

    private func showsQuickActions(for message: MailMessage) -> Bool {
        !message.isDraft && message.mailbox != .outbox && message.mailbox != .trash
    }

    private func quickActions(_ message: MailMessage) -> some View {
        HStack(spacing: 10) {
            Button {
                store.setStarred(!message.isStarred, for: [message.id])
            } label: {
                PostmereLabel(message.isStarred ? "Starred" : "Star", symbol: message.isStarred ? "star.fill" : "star", size: 13)
            }
            .help(message.isStarred ? "Remove star from this message" : "Star this message")
            .accessibilityValue(message.isStarred ? "On" : "Off")
            Button { runtime.schedulePurpose = .snooze } label: {
                PostmereLabel(message.workflow.snoozedUntil == nil ? "Snooze…" : "Reschedule Snooze…", symbol: "moon.zzz", size: 13)
            }
            .help("Choose when this conversation returns to the inbox")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder
    private func workflowSummary(_ message: MailMessage) -> some View {
        if let item = store.outgoingQueue.first(where: { $0.id == message.id }) {
            OutgoingStatusView(store: store, item: item).padding(.bottom, 16)
        }
        if message.workflow.screeningState == .pending {
            VStack(alignment: .leading, spacing: 10) {
                PostmereLabel("A new sender", symbol: "person.crop.circle.badge.questionmark", size: 16).font(.subheadline.weight(.medium))
                Text("Choose where future messages from \(message.senderEmail) should go.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Accept to Inbox") { store.acceptSender(of: message) }
                    Menu("Route to…") {
                        Button("Needs Reply") { store.acceptSender(of: message, route: .needsReply) }
                        Button("Archive") { store.acceptSender(of: message, route: .archive) }
                    }
                    Button("Block Sender", role: .destructive) { store.blockSender(of: message) }
                }.controlSize(.small)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(PostmereTheme.subtleFill, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius)).padding(.bottom, 16)
        }
        if message.workflow.needsReply {
            HStack {
                PostmereLabel("Needs reply", symbol: "arrowshape.turn.up.left", size: 14)
                Spacer()
                Button("Mark Done") { store.setNeedsReply(false, for: message.id) }
            }.font(.caption).controlSize(.small).padding(.bottom, 12)
        }
        if let date = message.workflow.snoozedUntil {
            HStack {
                PostmereLabel("Snoozed until \(date.formatted(date: .abbreviated, time: .shortened))", symbol: "moon.zzz", size: 14)
                Spacer()
                Button("Return to Inbox") { store.unsnoozeMessage(message.id) }
            }.font(.caption).controlSize(.small).padding(.bottom, 12)
        }
        if let date = message.workflow.followUpAt {
            HStack {
                PostmereLabel("Follow up \(date.formatted(date: .abbreviated, time: .shortened))\(message.workflow.followUpOnlyIfNoReply ? " if no reply" : "")", symbol: "bell", size: 14)
                Spacer()
                Button("Clear") { store.clearFollowUp(message.id) }
            }.font(.caption).controlSize(.small).padding(.bottom, 12)
        }
        if !message.workflow.privateNote.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                PostmereIcon("note.text", size: 16).foregroundStyle(.secondary)
                Text(message.workflow.privateNote).font(.caption).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Edit") { runtime.showsPrivateNote = true }.controlSize(.small)
            }.padding(12).background(PostmereTheme.subtleFill, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius)).padding(.bottom, 16)
        }
    }

    private func conversationSummary(_ messages: [MailMessage], selected: MailMessage) -> some View {
        let allExpanded = messages.allSatisfy { expandedMessageIDs.contains($0.id) }
        return HStack(spacing: 12) {
            PostmereLabel("\(messages.count) messages", symbol: "bubble.left.and.bubble.right", size: 14)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(allExpanded ? "Collapse earlier" : "Expand all") {
                expandedMessageIDs = allExpanded ? [selected.id] : Set(messages.map(\.id))
            }
            .buttonStyle(.borderless)
            .help(allExpanded ? "Keep only the selected message open" : "Read every message in this conversation")
        }
        .font(.system(size: 11))
    }

    private func conversationMessage(_ message: MailMessage) -> some View {
        let isExpanded = expandedMessageIDs.contains(message.id)
        let sender = message.isOutgoing ? "You" : message.sender
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    if isExpanded { expandedMessageIDs.remove(message.id) }
                    else { expandedMessageIDs.insert(message.id) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(message.initials)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(PostmereTheme.subtleFill, in: Circle())
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(sender)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(message.dateLabel), \(message.timeLabel)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(isExpanded ? "To: \(message.toRecipients.joined(separator: ", "))" : message.preview)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(isExpanded ? .middle : .tail)
                        }
                        PostmereIcon(isExpanded ? "chevron.down" : "chevron.right", size: 12)
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 16)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") message from \(sender), \(message.dateLabel), \(message.timeLabel)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                if isExpanded {
                    Button { presentedSheet = .messageDetails(message) } label: {
                        PostmereIcon("info.circle", size: 16).foregroundStyle(PostmereTheme.icon)
                    }
                    .buttonStyle(.borderless)
                    .help("Message details")
                    .accessibilityLabel("Message details for \(sender)'s message")
                }
            }
            .padding(16)

            if isExpanded {
                Divider().padding(.horizontal, 16)
                messageContents(message)
                    .padding(18)
            }
        }
        .background(isExpanded ? Color.clear : PostmereTheme.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
    }

    private func messageContents(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let body = formattedBody(for: message) {
                    Text(body)
                        .font(.system(size: readingFontSize))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(message.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.system(size: readingFontSize))
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)

            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.attachments.count == 1 ? "1 attachment" : "\(message.attachments.count) attachments")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(message.attachments) { attachment in
                        attachmentView(attachment, message: message)
                    }
                }
                .padding(.top, 24)
            }

            if message.mailbox != .outbox {
                Divider().padding(.top, 28).padding(.bottom, 18)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { responseButtons(message) }.fixedSize()
                    VStack(alignment: .leading, spacing: 8) { responseButtons(message) }
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedBody(for message: MailMessage) -> AttributedString? {
        guard let data = message.bodyRTF,
              let body = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else { return nil }
        // Embedded fonts retain their chosen sizes; the Text font supplies the reading-size fallback.
        return AttributedString(body)
    }

    private func senderHeader(_ message: MailMessage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message.initials)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(PostmereTheme.subtleFill, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(message.isOutgoing ? message.mailAccount.displayName : message.sender)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Button { presentedSheet = .messageDetails(message) } label: {
                        PostmereIcon("chevron.down", size: 12).foregroundStyle(PostmereTheme.icon)
                    }
                    .buttonStyle(.borderless)
                    .help("Show message details")
                    .accessibilityLabel("Show message details")
                    Spacer(minLength: 0)
                }
                Text(message.senderEmail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(message.senderEmail)
                    .textSelection(.enabled)
                Text("To: \(message.toRecipients.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(message.dateLabel), \(message.timeLabel) · \(message.accountLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private func messageDetails(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PostmereSheetHeader("Message details")
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    detailRow("From", message.senderEmail)
                    detailRow("To", message.toRecipients.joined(separator: ", "))
                    if !message.ccRecipients.isEmpty { detailRow("Cc", message.ccRecipients.joined(separator: ", ")) }
                    if message.isOutgoing && !message.bccRecipients.isEmpty {
                        detailRow("Bcc", message.bccRecipients.joined(separator: ", "))
                    }
                    detailRow("Date", "\(message.dateLabel), \(message.timeLabel)")
                    detailRow("Account", message.accountLabel)
                    detailRow("Mailbox", message.mailbox.title)
                }
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(width: 480, height: 340, alignment: .topLeading)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attachmentView(_ attachment: MailAttachment, message: MailMessage) -> some View {
        HStack(spacing: 10) {
            Button { resolveAttachment(attachment, message: message, save: false) } label: {
                HStack(spacing: 12) {
                    AttachmentIconView(attachment: attachment, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text(attachment.localURL == nil && attachment.providerAttachmentID == nil ? "Attachment file unavailable" : attachment.detail)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled((attachment.localURL == nil && attachment.providerAttachmentID == nil) || loadingAttachmentID == attachment.id)
            .help("Quick Look \(attachment.name)")
            .accessibilityLabel("Preview \(attachment.name)")
            if loadingAttachmentID == attachment.id { ProgressView().controlSize(.small) }
            else if attachment.localURL != nil || attachment.providerAttachmentID != nil {
                Button { resolveAttachment(attachment, message: message, save: true) } label: { PostmereIcon("arrow.down.to.line", size: 16).foregroundStyle(PostmereTheme.icon) }
                    .buttonStyle(.borderless)
                    .help("Save attachment…")
                    .accessibilityLabel("Save \(attachment.name)")
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(PostmereTheme.subtleFill, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
    }

    private func resolveAttachment(_ attachment: MailAttachment, message: MailMessage, save: Bool) {
        loadingAttachmentID = attachment.id
        Task {
            defer { loadingAttachmentID = nil }
            do {
                let resolved = try await runtime.resolveAttachment(attachment, in: message)
                if save { saveAttachment(resolved) }
                else if resolved.name.lowercased().hasSuffix(".ics"), let url = resolved.localURL,
                        let invitation = try MailCalendarInvitationParser.parse(data: Data(contentsOf: url)).first {
                    presentedSheet = .invitation(invitation, message.mailAccount)
                } else { presentedSheet = .attachment(resolved) }
            } catch { attachmentError = error.localizedDescription }
        }
    }

    private func saveAttachment(_ attachment: MailAttachment) {
        guard let source = attachment.localURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do { try Data(contentsOf: source).write(to: destination, options: .atomic) }
            catch { attachmentError = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func responseButtons(_ message: MailMessage) -> some View {
        Button { reply(to: message) } label: {
            PostmereLabel(primaryActionTitle(for: message),
                          symbol: message.isDraft ? "square.and.pencil" : "arrowshape.turn.up.left", size: 16)
        }
        .disabled(store.isComposing || (!message.isDraft && MailAccount.sendingAccounts.isEmpty))
        if !message.isDraft {
            Group {
                if store.hasReplyAllRecipients(for: message) {
                    Button { store.beginReplyAll(message) } label: {
                        PostmereLabel("Reply All", symbol: "arrowshape.turn.up.left.2", size: 16)
                    }
                }
                Button { store.beginForward(message) } label: {
                    PostmereLabel("Forward", symbol: "arrowshape.turn.up.right", size: 16)
                }
            }
            .disabled(store.isComposing || MailAccount.sendingAccounts.isEmpty)
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                if store.selectedMessage?.mailbox == .trash {
                    store.restoreSelected()
                } else if store.selectedMessage?.mailbox == .archive {
                    store.moveSelected(to: .inbox)
                } else { store.archiveSelected() }
            } label: {
                PostmereIcon(returnsToInbox ? "tray.and.arrow.down" : "archivebox", size: 17).foregroundStyle(PostmereTheme.icon)
            }
            .help(moveActionTitle)
            .accessibilityLabel(moveActionTitle)
            .disabled(store.selectedMessage == nil || (store.selectedMessage?.mailbox != .trash && !store.canMoveSelected(to: returnsToInbox ? .inbox : .archive)))

            Button { store.deleteSelected() } label: { PostmereIcon("trash", size: 17).foregroundStyle(PostmereTheme.icon) }
                .help("Move to Trash · ⌘Delete")
                .accessibilityLabel("Move to Trash")
                .disabled(!store.canMoveSelected(to: .trash))
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let message = store.selectedMessage {
                    if store.selectedMessageIDs.count <= 1 && !message.isDraft && message.mailbox != .outbox {
                        Button(message.workflow.needsReply ? "Mark Conversation Done" : "Needs Reply") { store.setNeedsReply(!message.workflow.needsReply, for: message.id) }
                        if !showsQuickActions(for: message) {
                            Button("Snooze…") { runtime.schedulePurpose = .snooze }
                        }
                        Button("Follow-up Reminder…") { runtime.schedulePurpose = .followUp }
                        Button("Private Note…") { runtime.showsPrivateNote = true }
                        Button("Sender Context…") { presentedSheet = .sender(message) }
                        if message.backendMessageID != nil {
                            Button("Share Conversation…") { presentedSheet = .share(message) }
                            Button("Summarize Conversation…") { presentedSheet = .ai(message, .summary) }
                            Button("Suggest Next Steps…") { presentedSheet = .ai(message, .suggestions) }
                        }
                        Divider()
                    }
                    if message.mailbox == .trash {
                        Button("Restore to \(store.restoreDestination(for: message).title)") { store.restoreSelected() }
                    }
                    if message.mailbox == .drafts && store.selectedMessageIDs.count <= 1 {
                        Button("Edit Draft", action: replyToSelectedMessage)
                            .disabled(store.isComposing)
                    } else if store.selectedMessageIDs.count <= 1 && !message.isDraft && message.mailbox != .outbox {
                        Button("Reply", action: replyToSelectedMessage)
                            .disabled(store.isComposing || MailAccount.sendingAccounts.isEmpty)
                        Button("Reply All") { store.beginReplyAll(message) }
                            .disabled(store.isComposing || MailAccount.sendingAccounts.isEmpty || !store.hasReplyAllRecipients(for: message))
                        Button("Forward") { store.beginForward(message) }
                            .disabled(store.isComposing || MailAccount.sendingAccounts.isEmpty)
                    }
                    Divider()
                    Button(message.isUnread ? "Mark as Read" : "Mark as Unread") { store.setRead(message.isUnread, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }
                    if store.selectedMessageIDs.count > 1 || !showsQuickActions(for: message) {
                        Button(message.isStarred ? "Remove Star" : "Star Message") { store.setStarred(!message.isStarred, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }
                    }
                    Menu("Move to") {
                        ForEach([Mailbox.inbox, .archive, .trash]) { destination in
                            Button(destination.title) { store.moveSelected(to: destination) }
                                .disabled(!store.canMoveSelected(to: destination))
                        }
                    }
                    Divider()
                    Button("Message Details") { presentedSheet = .messageDetails(message) }.disabled(store.selectedMessageIDs.count > 1)
                }
            } label: { PostmereIcon("ellipsis", size: 17).foregroundStyle(PostmereTheme.icon) }
            .help("More message actions")
            .accessibilityLabel("More message actions")
            .disabled(store.selectedMessage == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: replyToSelectedMessage) {
                PostmereLabel(primaryActionTitle,
                              symbol: store.selectedMessage?.isDraft == true ? "square.and.pencil" : "arrowshape.turn.up.left", size: 17)
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(PostmereTheme.icon)
            .help("\(primaryActionTitle) · ⌘R")
            .disabled(store.selectedMessage == nil || store.isComposing || store.selectedMessage?.mailbox == .outbox
                      || store.selectedMessageIDs.count > 1 || (store.selectedMessage?.isDraft != true && MailAccount.sendingAccounts.isEmpty))
        }
    }

    private var returnsToInbox: Bool {
        guard let message = store.selectedMessage else { return false }
        return message.mailbox == .archive || message.mailbox == .trash
    }

    private func replyToSelectedMessage() {
        guard let message = store.selectedMessage else { return }
        reply(to: message)
    }

    private func reply(to message: MailMessage) {
        if message.isDraft && message.mailbox == .trash {
            store.restoreMessage(message.id)
        } else if message.mailbox == .drafts { store.beginEditingDraft(message) }
        else { store.beginCompose(replyTo: message) }
    }

    private var primaryActionTitle: String {
        guard let message = store.selectedMessage else { return "Reply" }
        return primaryActionTitle(for: message)
    }

    private func primaryActionTitle(for message: MailMessage) -> String {
        guard message.isDraft else { return "Reply" }
        return message.mailbox == .trash ? "Restore Draft" : "Edit Draft"
    }

    private var moveActionTitle: String {
        if let message = store.selectedMessage, message.mailbox == .trash {
            return "Restore to \(store.restoreDestination(for: message).title)"
        }
        return returnsToInbox ? "Move to Inbox" : "Archive message · ⇧⌘A"
    }
}
