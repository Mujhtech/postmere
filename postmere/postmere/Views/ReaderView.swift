import SwiftUI
import AppKit

struct ReaderView: View {
    @Environment(\.postmereAccent) private var palette
    @Bindable var store: MailStore
    var compactToolbar = false
    @Environment(MailRuntime.self) private var runtime
    @AppStorage("readingFontSize") private var readingFontSize = 14.0
    @State private var presentedSheet: ReaderSheet?
    @State private var toolbarDetailsTarget: MailMessage?
    @State private var blockedTrackers: [UUID: Int] = [:]
    @State private var attachmentError: String?
    @State private var expandedMessageIDs: Set<UUID> = []
    @State private var loadingAttachmentID: UUID?
    @State private var readingPosition = ScrollPosition(edge: .top)
    @State private var detectedDates: (source: DateSource, suggestions: [MailDateSuggestion])?

    private struct DateSource: Equatable, Sendable {
        let messageID: UUID
        let paragraphs: [String]

        init(_ message: MailMessage) {
            messageID = message.id
            paragraphs = message.paragraphs
        }

        @concurrent func suggestions() async -> [MailDateSuggestion] {
            guard !Task.isCancelled, !paragraphs.isEmpty else { return [] }
            return MailDateDetector.suggestions(in: paragraphs.joined(separator: "\n\n"))
        }
    }

    private enum ReaderSheet: Identifiable {
        case attachment(MailAttachment)
        case unsubscribe(MailMessage)
        case calendar(MailCalendarEventDraft)
        case invitation(MailCalendarInvitation, MailAccount)
        case sender(MailMessage)
        case ai(MailMessage, MailAIMode)
        case share(MailMessage)

        var id: String {
            switch self {
            case .attachment(let attachment): "attachment-\(attachment.id)"
            case .unsubscribe(let message): "unsubscribe-\(message.id)"
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
                let conversation = store.selectedConversation
                let dateSource = DateSource(message)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(message.displaySubject)
                            .font(.system(size: 24, weight: .semibold, design: .serif))
                            .tracking(-0.4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, conversation.count > 1 ? 10 : 16)
                        if conversation.count > 1 {
                            conversationSummary(conversation, selected: message)
                                .padding(.bottom, 16)
                            workflowSummary(message)
                            VStack(spacing: 12) {
                                ForEach(conversation) { entry in
                                    conversationMessage(entry)
                                }
                            }
                        } else {
                            HoverableMailMessage {
                                VStack(alignment: .leading, spacing: 0) {
                                    senderHeader(message, presentation: .single)
                                    Divider().padding(.vertical, 14)
                                    workflowSummary(message)
                                    messageContents(message)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                }
                .scrollPosition($readingPosition)
                .task(id: dateSource, priority: .utility) {
                    let suggestions = await dateSource.suggestions()
                    guard !Task.isCancelled else { return }
                    detectedDates = (dateSource, suggestions)
                }
            } else if store.isSearchActive {
                searchPlaceholder
            } else {
                InboxOverviewView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if store.selectedMessage != nil || store.selectedMessageIDs.count > 1 { readerToolbar }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .attachment(let attachment): AttachmentPreviewSheet(attachment: attachment)
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
            readingPosition.scrollTo(edge: .top)
            presentedSheet = nil
            toolbarDetailsTarget = nil
            detectedDates = nil
            blockedTrackers.removeAll()
            expandedMessageIDs = Set([store.selectedMessageID].compactMap { $0 })
        }
        .alert("Unable to open attachment", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK") { attachmentError = nil }
        } message: { Text(attachmentError ?? "Please try again.") }
    }

    private var searchPlaceholder: some View {
        let unread = store.messages.lazy.filter { message in
            message.isUnread && store.matchesMailbox(message, mailbox: .inbox)
                && (store.selectedAccount == nil || store.selectedAccount == message.account)
        }.count
        return VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
                .padding(.bottom, 7)
                .accessibilityHidden(true)
            Text("No conversation selected")
                .font(.headline)
            Text("\(unread.formatted()) unread in Inbox")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbarMessage: MailMessage? {
        guard store.selectedMessageIDs.count <= 1, let message = store.selectedMessage,
              !message.isDraft, message.mailbox != .outbox, message.mailbox != .trash else { return nil }
        return message
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

    private func revealMessageInThread(_ id: UUID) {
        expandedMessageIDs.insert(id)
        let anchor = ThreadGroupAnchor(firstMessage: id)
        usesIndividualSourceTargets = true
        summarySourceAnchor = anchor
        readingPosition.scrollTo(id: anchor, anchor: .top)
    }

    private func conversationMessage(_ message: MailMessage, quoteThread: MailQuoteThread, prepared: Bool) -> some View {
        let isExpanded = expandedMessageIDs.contains(message.id)
        return HoverableMailMessage {
            VStack(alignment: .leading, spacing: 0) {
                senderHeader(message, presentation: isExpanded ? .expanded : .collapsed)
                    .padding(16)
                if isExpanded {
                    Divider().padding(.horizontal, 16)
                    messageContents(message).padding(16)
                }
            }
            .background(isExpanded ? Color.clear : PostmereTheme.subtleFill)
            .clipShape(RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
        }
    }

    private func messageContents(_ message: MailMessage, trackerCount: Binding<Int>, quoteContext: MailQuoteContext? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let html = message.receivedHTML {
                    HTMLMessageBody(html: html, paragraphs: message.paragraphs, fontSize: readingFontSize) { count in
                        if count > 0 { blockedTrackers[message.id] = count }
                        else { blockedTrackers.removeValue(forKey: message.id) }
                    }
                    .id(message.id)
                } else {
                    RichTextMessageBody(rtf: message.bodyRTF, paragraphs: message.paragraphs, fontSize: readingFontSize)
                        .id(message.id)
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


        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum HeaderPresentation {
        case single, expanded, collapsed
    }

    private func senderHeader(_ message: MailMessage, presentation: HeaderPresentation) -> some View {
        let name = message.isOutgoing ? (presentation == .single ? message.mailAccount.displayName : "You") : message.sender
        let sender = name.isEmpty ? message.senderEmail : name
        let avatarWidth: CGFloat = presentation == .single ? 36 : 32
        return VStack(alignment: .leading, spacing: 5) {
            senderIdentity(message, sender: sender, avatarWidth: avatarWidth, presentation: presentation, trackerCount: trackerCount)
            if presentation != .collapsed && message.mailbox != .junk && message.workflow.screeningState == .pending {
                SenderDeliveryChoice(address: message.senderEmail, avatarWidth: avatarWidth) { route in
                    store.acceptSender(of: message, route: route)
                } block: {
                    store.blockSender(of: message)
                }
            }
        }
        .task(id: presentation != .collapsed && automaticImages ? message.id : nil) {
            if presentation != .collapsed && automaticImages { await runtime.loadSenderMark(for: message) }
        }
    }

    private func senderIdentity(_ message: MailMessage, sender: String, avatarWidth: CGFloat,
                                presentation: HeaderPresentation, trackerCount: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            senderAvatar(message, size: avatarWidth)
            VStack(alignment: .leading, spacing: 4) {
                if presentation == .single {
                    senderLine(message, sender: sender, presentation: presentation)
                        .textSelection(.enabled)
                } else {
                    Button {
                        if presentation == .expanded { expandedMessageIDs.remove(message.id) }
                        else { expandedMessageIDs.insert(message.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            senderLine(message, sender: sender, presentation: presentation)
                            if presentation == .collapsed {
                                Text(message.preview).font(.system(size: 12))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(presentation == .expanded ? "Collapse" : "Expand") message from \(sender), \(message.dateLabel), \(message.timeLabel)")
                    .accessibilityValue(presentation == .expanded ? "Expanded" : "Collapsed")
                }
                if presentation != .collapsed {
                    HStack(spacing: 6) {
                        recipientSummary(message)
                        Spacer(minLength: 0)
                        hoverResponseButtons(message)
                    }
                    messageNotices(message)
                }
            }
        }
    }

    private func senderLine(_ message: MailMessage, sender: String, presentation: HeaderPresentation) -> some View {
        let name = Text(sender).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        let address = Text(message.senderEmail).font(.system(size: 12)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).help(message.senderEmail)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if presentation != .collapsed, !message.senderEmail.isEmpty,
               sender.caseInsensitiveCompare(message.senderEmail) != .orderedSame {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        name
                        address
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        name
                        address
                    }
                }
            } else {
                name
            }
            Spacer(minLength: 0)
            Text("\(message.dateLabel), \(message.timeLabel)")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            if presentation != .single {
                PostmereIcon(presentation == .expanded ? "chevron.down" : "chevron.right", size: 12)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func messageNotices(_ message: MailMessage) -> some View {
        let trackerCount = blockedTrackers[message.id, default: 0]
        let canUnsubscribe = MailUnsubscribeService.options(for: message).isAvailable
        let showsActivity = message.isOutgoing && message.mailbox == .sent
        if trackerCount > 0 || canUnsubscribe || showsActivity {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if trackerCount > 0 {
                    Label(trackerCount == 1 ? "1 tracker blocked" : "\(trackerCount) trackers blocked", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                        .help("Postmere prevented these tracking pixels from loading.")
                }
                if canUnsubscribe {
                    Button("Unsubscribe…") { presentedSheet = .unsubscribe(message) }
                        .foregroundStyle(palette.accentInk)
                        .help("Review unsubscribe options for this mailing list")
                }
                if showsActivity {
                    MessageActivityButton(message: message, session: runtime.backend)
                        .id(store.selectedMessageID)
                    if message.trackOpens != true && message.trackLinks != true {
                        Text("Tracking off").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func hoverResponseButtons(_ message: MailMessage) -> some View {
        if message.mailbox != .outbox {
            HoverResponseControls {
                responseButtons(message)
            }
        }
    }

    private func senderAvatar(_ message: MailMessage, size: CGFloat) -> some View {
        MailParticipantAvatar(address: message.senderEmail, name: message.isOutgoing ? message.mailAccount.displayName : message.sender,
                              size: size, messageID: message.id)
    }

    private func recipientAddresses(_ values: [String]) -> [String] {
        values.flatMap { value in
            let parsed = MailAddressList(value)
            return parsed.invalid.isEmpty ? parsed.addresses : [value]
        }
    }

    private func recipientName(_ address: String, message: MailMessage) -> String {
        if let name = message.envelopeDetails?.recipientNames[address.lowercased()] { return name }
        guard address.caseInsensitiveCompare(message.mailAccount.email) == .orderedSame else { return "" }
        return message.mailAccount.displayName
    }

    private func recipientSummary(_ message: MailMessage) -> some View {
        let addresses = recipientAddresses(message.toRecipients)
        return HStack(spacing: 5) {
            Text("To:")
            if let first = addresses.first {
                MailParticipantAvatar(address: first, name: recipientName(first, message: message), size: 20, messageID: message.id)
                Text(first).lineLimit(1).truncationMode(.middle)
            } else {
                Text("—")
            }
            MessageDetailsDisclosure(message: message, additionalRecipients: max(0, addresses.count - 1))
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
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
                if attachment.isCalendarFile {
                    let data = try await runtime.calendarInvitationBytes(attachment: attachment, message: message)
                    if save { saveAttachment(attachment, data: data) }
                    else if let invitation = try await MailCalendarInvitationParser.parseInBackground(data).first {
                        presentedSheet = .invitation(invitation, message.mailAccount)
                    }
                    return
                }
                let resolved = try await runtime.resolveAttachment(attachment, in: message)
                if save { saveAttachment(resolved) }
                else { presentedSheet = .attachment(resolved) }
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
                          symbol: message.isDraft ? "square.and.pencil" : "arrowshape.turn.up.left", size: 15)
                .frame(minWidth: 26, minHeight: 24)
        }
        .help(primaryActionTitle(for: message))
        .disabled(store.isComposing || (!message.isDraft && MailAccount.sendingAccounts.isEmpty))
        if !message.isDraft {
            Group {
                if store.hasReplyAllRecipients(for: message) {
                    Button { store.beginReplyAll(message) } label: {
                        PostmereLabel("Reply All", symbol: "arrowshape.turn.up.left.2", size: 15)
                            .frame(minWidth: 26, minHeight: 24)
                    }.help("Reply All")
                }
                Button { store.beginForward(message) } label: {
                    PostmereLabel("Forward", symbol: "arrowshape.turn.up.right", size: 15)
                        .frame(minWidth: 26, minHeight: 24)
                }.help("Forward")
            }
            .disabled(store.isComposing || MailAccount.sendingAccounts.isEmpty)
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            let message = toolbarMessage
            MessageLabelButton(message: syncedToolbarMessage)

            let starred = message?.isStarred == true
            let starTitle = starred ? "Remove Star" : "Star Message"
            Button {
                if let selected = toolbarMessage { store.toggleStar(selected.id) }
            } label: {
                PostmereLabel(starTitle, symbol: starred ? "star.fill" : "star", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(starred ? palette.accentInk : PostmereTheme.icon)
            }
            .help(starTitle)
            .accessibilityValue(starred ? "On" : "Off")
            .disabled(message == nil)

            let snoozeTitle = message?.workflow.snoozedUntil == nil ? "Snooze Conversation…" : "Reschedule Snooze…"
            Button { runtime.schedulePurpose = .snooze } label: {
                PostmereLabel(snoozeTitle, symbol: "moon.zzz", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(PostmereTheme.icon)
            }
            .help(snoozeTitle)
            .disabled(message == nil)


            Button {
                if store.selectedMessage?.mailbox == .trash {
                    store.restoreSelected()
                } else if store.selectedMessage?.mailbox == .archive {
                    store.moveSelected(to: .inbox)
                } else { store.archiveSelected() }
            } label: {
                PostmereLabel(moveActionTitle, symbol: returnsToInbox ? "tray.and.arrow.down" : "archivebox", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(PostmereTheme.icon)
            }
            .help(returnsToInbox ? moveActionTitle : "\(moveActionTitle) · ⇧⌘A")
            .disabled(store.selectedMessage == nil || (store.selectedMessage?.mailbox != .trash && !store.canMoveSelected(to: returnsToInbox ? .inbox : .archive)))

            Button { store.deleteSelected() } label: {
                PostmereLabel("Move to Trash", symbol: "trash", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(PostmereTheme.icon)
            }
                .help("Move to Trash · ⌘Delete")
                .disabled(!store.canMoveSelected(to: .trash))
        }
        if !compactToolbar { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let message = syncedToolbarMessage { presentedSheet = .ai(message, .summary) }
            } label: {
                PostmereLabel("Summarize Conversation", symbol: "sparkles", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(PostmereTheme.icon)
            }
            .help("Summarize this conversation")
            .disabled(syncedToolbarMessage == nil)

            Menu { additionalMessageActions } label: {
                PostmereLabel("More Message Actions", symbol: "ellipsis", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(PostmereTheme.icon)
            }
            .menuIndicator(.hidden)
            .help("More message actions")
            .popover(item: $toolbarDetailsTarget) { message in
                MessageEnvelopeDetailsView(message: message).id(message.id)
            }
            .disabled(store.selectedMessage == nil)
        }
        .visibilityPriority(.high)
        if !compactToolbar { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItem(placement: .primaryAction) {
            if store.selectedMessage?.isDraft == true {
                Button(action: replyToSelectedMessage) {
                    PostmereLabel(primaryActionTitle, symbol: "square.and.pencil", size: 17)
                }
                .labelStyle(.titleAndIcon)
                .help("\(primaryActionTitle) · ⌘R")
                .disabled(store.isComposing || store.selectedMessageIDs.count > 1)
            } else {
                Menu {
                    Button("Reply", action: replyToSelectedMessage)
                    Button("Reply All") {
                        if let message = store.selectedMessage { store.beginReplyAll(message) }
                    }
                    .disabled(store.selectedMessage.map { !store.hasReplyAllRecipients(for: $0) } ?? true)
                    Button("Forward") {
                        if let message = store.selectedMessage { store.beginForward(message) }
                    }
                } label: {
                    let label = PostmereLabel("Reply", symbol: "arrowshape.turn.up.left", size: 17)
                    if compactToolbar { label.labelStyle(.iconOnly) }
                    else { label.labelStyle(.titleAndIcon) }
                } primaryAction: {
                    replyToSelectedMessage()
                }
                .help("Reply · ⌘R")
                .disabled(store.selectedMessage == nil || store.isComposing || store.selectedMessage?.mailbox == .outbox
                          || store.selectedMessageIDs.count > 1 || MailAccount.sendingAccounts.isEmpty)
            }
        }
        .visibilityPriority(.high)
    }

    @ViewBuilder private var additionalMessageActions: some View {
        if let message = store.selectedMessage {
            if store.selectedMessageIDs.count <= 1 && !message.isDraft && message.mailbox != .outbox {
                Button(message.workflow.needsReply ? "Mark Conversation Done" : "Needs Reply") { store.setNeedsReply(!message.workflow.needsReply, for: message.id) }
                if toolbarMessage == nil {
                    Button("Snooze…") { runtime.schedulePurpose = .snooze }
                }
                Button("Follow-up Reminder…") { runtime.schedulePurpose = .followUp }
                Button("Private Note…") { runtime.showsPrivateNote = true }
                Button("Sender Context…") { presentedSheet = .sender(message) }
                if message.backendMessageID != nil {
                    Button("Share Conversation…") { presentedSheet = .share(message) }
                    Button("Suggest Next Steps…") { presentedSheet = .ai(message, .suggestions) }
                }
                Divider()
            }
            if message.mailbox == .trash {
                Button("Restore to \(store.restoreDestination(for: message).title)") { store.restoreSelected() }
            }
            Button(message.isUnread ? "Mark as Read" : "Mark as Unread") { store.setRead(message.isUnread, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }
            if toolbarMessage == nil {
                Button(message.isStarred ? "Remove Star" : "Star Message") { store.setStarred(!message.isStarred, for: store.selectedMessageIDs.isEmpty ? [message.id] : store.selectedMessageIDs) }
            }
            Menu("Move to") {
                ForEach([Mailbox.inbox, .archive, .trash]) { destination in
                    Button(destination.title) { store.moveSelected(to: destination) }
                        .disabled(!store.canMoveSelected(to: destination))
                }
            }
            Divider()
            if store.selectedMessageIDs.count <= 1, let detectedDates,
               detectedDates.source == DateSource(message), !detectedDates.suggestions.isEmpty {
                Menu("Create Calendar Event") {
                    ForEach(detectedDates.suggestions) { suggestion in
                        Button(suggestion.matchedText) {
                            presentedSheet = .calendar(suggestion.eventDraft(title: message.subject))
                        }
                    }
                }
            }
            Button("Message Details") { toolbarDetailsTarget = message }.disabled(store.selectedMessageIDs.count > 1)
        }
    }

    private var syncedToolbarMessage: MailMessage? {
        guard store.selectedMessageIDs.count <= 1, let message = store.selectedMessage,
              message.backendMessageID != nil, !message.isDraft, message.mailbox != .outbox else { return nil }
        return message
    }

    private func summarizeConversation() {
        guard let message = syncedToolbarMessage else { return }
        let session = runtime.backend
        var sourceIDs: [UUID] = []
        if let scope = session.scope, message.mailAccount.remote?.scope == scope,
           let selectedID = message.backendMessageID {
            // The API accepts 30 sources. Prefer recent mail and always include the
            // message the reader is on, even in a conversation longer than that.
            var seen: Set<UUID> = []
            for entry in store.selectedConversation.reversed() {
                guard entry.mailAccount.remote?.scope == scope,
                      let id = entry.backendMessageID, seen.insert(id).inserted else { continue }
                sourceIDs.append(id)
                if sourceIDs.count == 30 { break }
            }
            if !seen.contains(selectedID) {
                if sourceIDs.count == 30 { sourceIDs.removeLast() }
                sourceIDs.append(selectedID)
            }
            sourceIDs.reverse()
        }
        if let current = summaryTarget, current.messageID == message.id,
           current.sessionID == session.realtimeGeneration, current.sourceIDs == sourceIDs {
            if case .failed = current.phase { current.start() }
        } else {
            summaryTarget = MailConversationSummary(messageID: message.id, sessionID: session.realtimeGeneration, sourceIDs: sourceIDs)
        }
        isSummaryExpanded = true
        summarySourceAnchor = nil
        readingPosition.scrollTo(edge: .top)
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
        return returnsToInbox ? "Move to Inbox" : "Archive Message"
    }
}

private extension EnvironmentValues {
    @Entry var hoveringMailMessage = false
}

private struct HoverableMailMessage<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var isHovered = false

    var body: some View {
        content
            .environment(\.hoveringMailMessage, isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private struct HoverResponseControls<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.hoveringMailMessage) private var isHovered
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @FocusState private var hasFocus: Bool

    var body: some View {
        let visible = isHovered || hasFocus || voiceOver
        HStack(spacing: 1) { content }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .padding(.horizontal, 4)
            .background(PostmereTheme.subtleFill, in: Capsule())
            .foregroundStyle(PostmereTheme.icon)
            .fixedSize()
            .focused($hasFocus)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}
