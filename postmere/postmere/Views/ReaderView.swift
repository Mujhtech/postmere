import SwiftUI
import AppKit

struct ReaderView: View {
    @Environment(\.mailboxInset) private var inset
    @Environment(\.postmereAccent) private var palette
    @Bindable var store: MailStore
    var compactToolbar = false
    @Environment(MailRuntime.self) private var runtime
    @AppStorage("loadRemoteMailImagesAutomatically") private var automaticImages = true
    @AppStorage("readingFontSize") private var readingFontSize = 14.0
    @AppStorage(MailReadingFont.preference) private var readingFont = MailReadingFont.original
    @State private var presentedSheet: ReaderSheet?
    @State private var trashKick = 0
    @State private var archiveKick = 0
    @State private var starKick = 0
    @State private var snoozeKick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var noteDrafts: [UUID: String] = [:]
    @State private var attachmentError: String?
    @State private var expandedMessageIDs: Set<UUID> = []
    @State private var loadingAttachmentID: UUID?
    @State private var readingPosition = ScrollPosition(idType: ThreadGroupAnchor.self)
    @State private var summarySourceAnchor: ThreadGroupAnchor?
    @State private var usesIndividualSourceTargets = false
    @State private var viewportHeight: CGFloat = 0
    @State private var detectedDates: (source: DateSource, suggestions: [MailDateSuggestion])?
    @State private var summaryTarget: MailConversationSummary?
    @State private var isSummaryExpanded = true
    @State private var senderResearch = MailSenderProfile()
    @State private var senderDetailsSelection: SenderSelection?
    @State private var senderLookupTask: Task<Void, Never>?
    @State private var readerSize: CGSize = .zero
    @State private var isEnablingSenderResearch = false
    @State private var senderEnableError: String?

    private struct SenderSelection {
        enum Action { case lookup, refresh, enable }
        let id = UUID()
        let readerID: UUID
        let messageID: UUID
        let email: String
        let account: String
        let target: SenderProfileTarget?
        let action: Action
    }

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
        case invitation(MailCalendarInvitation, MailAccount)

        var id: String {
            switch self {
            case .attachment(let attachment): "attachment-\(attachment.id)"
            case .unsubscribe(let message): "unsubscribe-\(message.id)"
            case .invitation(let invitation, _): "invitation-\(invitation.id)"
            }
        }
    }

    /// The open message, selection or overview. A message moved out of the
    /// reader, or brought back by Undo, animates rather than swapping instantly.
    private var readerContent: some View {
        // Overlapping so a departing message and its successor share the space.
        ZStack {
            if store.selectedMessageIDs.count > 1 {
                MultiSelectionView(store: store)
            } else if let message = store.selectedMessage {
                openMessage(message)
            } else if store.isSearchActive {
                searchPlaceholder
            } else {
                InboxOverviewView(store: store)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.1), value: store.departure?.id)
        .onChange(of: store.departure?.id) {
            // The button that caused the move reacts, with a light tap for removals.
            guard let departure = store.departure else { return }
            switch departure.destination {
            case .trash, .junk:
                trashKick += 1
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            case .archive, .inbox, nil:
                archiveKick += 1
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            case .snoozed:
                snoozeKick += 1
            default: break
            }
        }
    }

    var body: some View {
        readerContent
        // Revealing the panel asks the split layout for enough room to retain
        // a readable message; it never becomes a modal inspector at small sizes.
        .frame(minWidth: showsSenderDetails ? 661 : nil, maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { readerSize = $0 }
        .onChange(of: activeSenderRequestID) { _, requestID in
            if requestID == nil, senderDetailsSelection?.target != nil { closeSenderDetails() }
        }
        .onDisappear(perform: closeSenderDetails)
        .onChange(of: runtime.readerPanel?.id) {
            if runtime.readerPanel != nil { closeSenderDetails() }
        }
        .toolbar {
            if store.selectedMessage != nil || store.selectedMessageIDs.count > 1 { readerToolbar }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .attachment(let attachment): AttachmentPreviewSheet(attachment: attachment)
            case .invitation(let invitation, let account):
                CalendarInvitationSheet(invitation: invitation, session: runtime.backend, account: account)
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
        .task(id: summaryTarget?.requestID) {
            // Keep generation alive when the lazy reader scrolls its summary offscreen.
            if let summaryTarget { await summaryTarget.load(session: runtime.backend) }
        }
        .onChange(of: runtime.backend.realtimeGeneration) {
            summaryTarget = nil
            closeSenderDetails()
        }
        .onChange(of: store.selectedAccount) {
            runtime.readerPanel = nil
            closeSenderDetails()
        }
        .onChange(of: store.selectedMessageIDs.count > 1) { _, multiple in
            if multiple { runtime.readerPanel = nil; summaryTarget = nil; closeSenderDetails() }
        }
        .onChange(of: runtime.backend.scope) {
            noteDrafts.removeAll()
            runtime.readerPanel = nil
        }
        .onChange(of: store.selectedMessageID, initial: true) {
            closeSenderDetails()
            readingPosition.scrollTo(edge: .top)
            summarySourceAnchor = nil
            usesIndividualSourceTargets = false
            presentedSheet = nil
            if runtime.readerPanel?.messageID != store.selectedMessageID { runtime.readerPanel = nil }
            summaryTarget = nil
            detectedDates = nil
            expandedMessageIDs = Set([store.selectedMessageID].compactMap { $0 })
        }
        .alert("Unable to open attachment", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK") { attachmentError = nil }
        } message: { Text(attachmentError ?? "Please try again.") }
    }

    /// The reader for one message, beside the optional sender details panel.
    private func openMessage(_ message: MailMessage) -> some View {
        HSplitView {
            readerWithActions(message)
                .frame(minWidth: showsSenderDetails ? 380 : nil, maxWidth: .infinity, maxHeight: .infinity)
            if showsSenderDetails, let sender = senderDetailsMessage {
                SenderContextView(message: sender, target: senderProfileTarget, research: senderResearch,
                                  onRefresh: { requestSenderDetails(.refresh) }, onClose: closeSenderDetails,
                                  onEnable: { requestSenderDetails(.enable) }, isEnabling: isEnablingSenderResearch, enableError: senderEnableError)
                    .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
            }
        }
        // Identity changes only when a message leaves or returns, so
        // ordinary navigation keeps the same reader and web view.
        .id(store.departure?.id)
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .readerArrival, removal: .readerDeparture(store)))
    }

    private func readerWithActions(_ message: MailMessage) -> some View {
        let beside = readerSize.width >= 690
        let layout = beside ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            readingContent(message, conversation: store.selectedConversation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let request = runtime.readerPanel, request.messageID == message.id {
                Rectangle().fill(.separator)
                    .frame(width: beside ? 1 : nil, height: beside ? nil : 1)
                    .accessibilityHidden(true)
                ReaderActionPanel(request: request, message: message, runtime: runtime, noteDrafts: $noteDrafts) {
                    guard runtime.readerPanel?.id == request.id else { return }
                    closeActionPanel()
                }
                .id(request.id)
                .frame(width: beside ? min(360, readerSize.width * 0.45) : nil,
                       height: beside ? nil : min(340, readerSize.height * 0.47))
            }
        }
    }

    @ViewBuilder private func readingContent(_ message: MailMessage, conversation: [MailMessage]) -> some View {
        let groups = ThreadMessageGroup.groups(in: conversation, individualTargets: usesIndividualSourceTargets)
        let dateSource = DateSource(message)
        let keepsSourceAtTop = summarySourceAnchor != nil
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(message.displaySubject)
                        .font(.system(size: 24, weight: .semibold, design: .serif))
                        .tracking(-0.4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, conversation.count > 1 ? 10 : 16)
                    if let target = summaryTarget, target.messageID == message.id,
                       target.sessionID == runtime.backend.realtimeGeneration {
                        MailConversationSummaryView(summary: target,
                                                   isExpanded: $isSummaryExpanded) { sourceID in
                            if let source = conversation.first(where: { $0.backendMessageID == sourceID }) {
                                revealMessageInThread(source.id)
                            }
                        }
                        .id(target.id)
                        .padding(.bottom, 16)
                    }
                    if conversation.count > 1 {
                        conversationSummary(conversation, selected: message)
                            .padding(.bottom, 8)
                        workflowSummary(message, conversation: conversation)
                        let quoteThread = MailQuoteThread(messages: conversation)
                        ForEach(groups) { group in
                            ProgressiveThreadGroup(group: group, expanded: expandedMessageIDs,
                                                   priorityID: summarySourceAnchor?.firstMessage ?? message.id) { entry, prepared in
                                VStack(alignment: .leading, spacing: 0) {
                                    if entry.id != conversation.first?.id { Divider() }
                                    conversationMessage(entry, quoteThread: quoteThread, prepared: prepared)
                                }
                                .id(entry.id)
                            }
                            // Give a linked source room to align before its HTML has finished measuring.
                            .frame(minHeight: summarySourceAnchor == group.id ? viewportHeight : nil, alignment: .topLeading)
                            .id(group.id)
                        }
                    } else {
                        HoverableMailMessage { trackerCount in
                            VStack(alignment: .leading, spacing: 0) {
                                senderHeader(message, presentation: .single, trackerCount: trackerCount.wrappedValue)
                                Divider().padding(.vertical, 14)
                                workflowSummary(message, conversation: conversation)
                                messageContents(message, trackerCount: trackerCount)
                            }
                        }
                        .id(ThreadGroupAnchor(firstMessage: message.id))
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
            .scrollPosition($readingPosition)
            // A distant source can move as neighbouring HTML messages acquire their actual heights.
            .onScrollGeometryChange(for: CGFloat.self, of: { keepsSourceAtTop ? $0.contentSize.height : 0 }) { _, _ in
                if let summarySourceAnchor { reader.scrollTo(summarySourceAnchor, anchor: .top) }
            }
            .onChange(of: summarySourceAnchor) {
                if let summarySourceAnchor { reader.scrollTo(summarySourceAnchor, anchor: .top) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting { summarySourceAnchor = nil }
            }
        }
        .task(id: dateSource, priority: .utility) {
            let suggestions = await dateSource.suggestions()
            guard !Task.isCancelled else { return }
            detectedDates = (dateSource, suggestions)
        }
    }

    private var showsSenderDetails: Bool {
        senderDetailsMessage != nil
    }

    private func closeActionPanel() {
        closeSenderDetails()
        runtime.readerPanel = nil
    }

    private func toggleActionPanel(_ action: ReaderPanelAction) {
        if runtime.readerPanel?.action == action { closeActionPanel() }
        else { runtime.openReaderPanel(action) }
    }

    private var senderDetailsMessage: MailMessage? {
        guard let choice = senderDetailsSelection, runtime.readerPanel == nil,
              store.selectedMessageIDs.count <= 1, let selected = store.selectedMessage,
              selected.id == choice.readerID else { return nil }
        let message = selected.id == choice.messageID ? selected : store.selectedConversation.first { $0.id == choice.messageID }
        guard let message, message.account == choice.account,
              message.senderEmail.caseInsensitiveCompare(choice.email) == .orderedSame else { return nil }
        return message
    }

    private var senderProfileTarget: SenderProfileTarget? {
        guard let target = senderDetailsSelection?.target, let message = senderDetailsMessage,
              SenderProfileTarget.make(message: message, scope: runtime.backend.scope,
                                       sessionGeneration: runtime.backend.realtimeGeneration) == target else { return nil }
        return target
    }

    private var activeSenderRequestID: UUID? {
        senderProfileTarget == nil ? nil : senderDetailsSelection?.id
    }

    private func closeSenderDetails() {
        senderDetailsSelection = nil
        senderLookupTask?.cancel()
        senderLookupTask = nil
        senderResearch.cancel()
        isEnablingSenderResearch = false
        senderEnableError = nil
    }

    private func selectSenderDetails(_ message: MailMessage, action: SenderSelection.Action = .lookup) {
        guard store.selectedMessageIDs.count <= 1, let readerID = store.selectedMessageID else { return }
        let target = SenderProfileTarget.make(message: message, scope: runtime.backend.scope,
                                              sessionGeneration: runtime.backend.realtimeGeneration)
        if action == .lookup, let choice = senderDetailsSelection, choice.readerID == readerID,
           choice.messageID == message.id, choice.target == target, showsSenderDetails { return }
        closeSenderDetails()
        runtime.readerPanel = nil
        let choice = SenderSelection(readerID: readerID, messageID: message.id,
                                     email: message.senderEmail, account: message.account,
                                     target: target, action: action)
        senderDetailsSelection = choice
        if target != nil {
            senderLookupTask = Task { await loadSenderDetails(choice) }
        }
    }

    private func requestSenderDetails(_ action: SenderSelection.Action) {
        guard let message = senderDetailsMessage, senderProfileTarget != nil, !isEnablingSenderResearch else { return }
        selectSenderDetails(message, action: action)
    }

    private func loadSenderDetails(_ choice: SenderSelection) async {
        guard let target = choice.target, !Task.isCancelled, activeSenderRequestID == choice.id else { return }
        if choice.action == .enable {
            isEnablingSenderResearch = true
            defer { if senderDetailsSelection?.id == choice.id { isEnablingSenderResearch = false } }
            do {
                let settings: MailAISettings = try await runtime.backend.request("GET", "/v1/ai/settings")
                guard !Task.isCancelled, activeSenderRequestID == choice.id else { return }
                if !settings.enabled {
                    let _: MailAISettings = try await runtime.backend.request("PUT", "/v1/ai/settings",
                        body: MailAISettingsInput(enabled: true, styleGuide: settings.styleGuide))
                }
            } catch {
                if !Task.isCancelled, activeSenderRequestID == choice.id { senderEnableError = error.localizedDescription }
                return
            }
        }
        await senderResearch.load(target: target, refresh: choice.action != .lookup,
                                  isCurrent: { activeSenderRequestID == choice.id }) { messageID, input in
            try await runtime.backend.request(SenderProfileRequest.method, SenderProfileRequest.path(messageID: messageID), body: input)
        }
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
              message.allowsWorkflowActions, message.mailbox != .trash else { return nil }
        return message
    }

    @ViewBuilder
    private func workflowSummary(_ message: MailMessage, conversation: [MailMessage]) -> some View {
        if let item = store.outgoingQueue.first(where: { $0.id == message.id }) {
            OutgoingStatusView(store: store, item: item).padding(.bottom, 16)
        }
        if let annotation = NeedsReplyAnnotation(selected: message, conversation: conversation) {
            NeedsReplyAnnotationView(annotation: annotation, inThread: conversation.count > 1) {
                revealMessageInThread(annotation.messageID)
            } markDone: {
                store.setNeedsReply(false, for: annotation.messageID)
            }
            .padding(.bottom, 16)
        }
        if message.mailbox != .junk, let date = message.workflow.snoozedUntil {
            HStack {
                PostmereLabel("Snoozed until \(date.formatted(date: .abbreviated, time: .shortened))", symbol: "moon.zzz", size: 14)
                Spacer()
                Button("Return to Inbox") { store.unsnoozeMessage(message.id) }
            }.font(.caption).controlSize(.small).padding(.bottom, 12)
        }
        if message.mailbox != .junk, let date = message.workflow.followUpAt {
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
                Button("Edit") { runtime.openReaderPanel(.privateNote) }.controlSize(.small)
            }.padding(12).background(inset, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius)).padding(.bottom, 16)
        }
    }

    private func conversationSummary(_ messages: [MailMessage], selected: MailMessage) -> some View {
        let allExpanded = messages.allSatisfy { expandedMessageIDs.contains($0.id) }
        return HStack(spacing: 12) {
            PostmereLabel("\(messages.count) messages", symbol: "bubble.left.and.bubble.right", size: 14)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(allExpanded ? "Collapse earlier" : "Expand all") {
                summarySourceAnchor = nil
                usesIndividualSourceTargets = false
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
        return HoverableMailMessage { trackerCount in
            VStack(alignment: .leading, spacing: 0) {
                senderHeader(message, presentation: isExpanded ? .expanded : .collapsed, trackerCount: trackerCount.wrappedValue)
                    .padding(.vertical, 12)
                if isExpanded {
                    if prepared || message.receivedHTML == nil {
                        messageContents(message, trackerCount: trackerCount, quoteContext: quoteThread.context(for: message))
                            .padding(.bottom, 16)
                    } else {
                        Text(verbatim: message.displayPreview)
                            .font(readingFont.font(size: readingFontSize))
                            .lineLimit(3)
                            .padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private func messageContents(_ message: MailMessage, trackerCount: Binding<Int>, quoteContext: MailQuoteContext? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SpamCheckView(message: message, store: store)
            if !message.isDraft && message.mailbox != .outbox {
                MailMessageInvitation(message: message, runtime: runtime) { event in
                    presentedSheet = .invitation(event, message.mailAccount)
                }
                .id("invitation-\(message.id)")
            }
            MailVerificationCodeView(message: message) { EmptyView() }
            Group {
                if let html = message.receivedHTML {
                    HTMLMessageBody(html: html, paragraphs: message.paragraphs, fontSize: readingFontSize, readingFont: readingFont, quoteContext: quoteContext) { count in
                        if trackerCount.wrappedValue != count { trackerCount.wrappedValue = count }
                    }
                } else {
                    RichTextMessageBody(rtf: message.bodyRTF, paragraphs: message.paragraphs, fontSize: readingFontSize, readingFont: readingFont, quoteContext: quoteContext)
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

    private func senderHeader(_ message: MailMessage, presentation: HeaderPresentation, trackerCount: Int) -> some View {
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
                    Button { selectSenderDetails(message) } label: {
                        senderLine(message, sender: sender, presentation: presentation)
                    }.buttonStyle(.plain).help("Show sender details")
                        .accessibilityLabel("Show sender details for \(sender)")
                } else {
                    Button {
                        summarySourceAnchor = nil
                        if presentation == .expanded { expandedMessageIDs.remove(message.id) }
                        else { expandedMessageIDs.insert(message.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            senderLine(message, sender: sender, presentation: presentation)
                            if presentation == .collapsed, !message.displayPreview.isEmpty {
                                Text(verbatim: message.displayPreview).font(.system(size: 12))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(presentation == .expanded ? "Collapse" : "Expand") message from \(sender), \(message.dateLabel), \(message.timeLabel)")
                    .accessibilityValue(presentation == .expanded ? "Expanded" : "Collapsed")
                    .contextMenu { spamCheckAction(message) }
                }
                if presentation != .collapsed {
                    HStack(spacing: 6) {
                        recipientSummary(message)
                        Spacer(minLength: 0)
                        hoverResponseButtons(message)
                    }
                    messageNotices(message, trackerCount: trackerCount)
                }
            }
        }
    }

    private func senderLine(_ message: MailMessage, sender: String, presentation: HeaderPresentation) -> some View {
        let name = Text(sender).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        let pending = message.mailbox != .junk && message.workflow.screeningState == .pending
        let address = Text(verbatim: message.senderEmail).font(.system(size: pending ? 13 : 12))
            .foregroundStyle(pending ? Color.primary : Color.secondary)
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

    @ViewBuilder private func messageNotices(_ message: MailMessage, trackerCount: Int) -> some View {
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
        Button { selectSenderDetails(message) } label: {
            MailParticipantAvatar(address: message.senderEmail, name: message.isOutgoing ? message.mailAccount.displayName : message.sender,
                                  size: size, messageID: message.id, verifiedMark: message.currentSenderMark)
        }.buttonStyle(.plain).help("Show sender details")
            .accessibilityLabel("Show sender details for \(message.senderEmail)")
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
        let available = attachment.localURL != nil || attachment.providerAttachmentID != nil || attachment.inlineCalendarData != nil
        return HStack(spacing: 10) {
            Button { resolveAttachment(attachment, message: message, save: false) } label: {
                HStack(spacing: 12) {
                    AttachmentIconView(attachment: attachment, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text(available ? attachment.detail : "Attachment file unavailable")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!available || loadingAttachmentID == attachment.id)
            .help("Quick Look \(attachment.name)")
            .accessibilityLabel("Preview \(attachment.name)")
            if loadingAttachmentID == attachment.id { ProgressView().controlSize(.small) }
            else if available {
                Button { resolveAttachment(attachment, message: message, save: true) } label: { PostmereIcon("arrow.down.to.line", size: 16).foregroundStyle(PostmereTheme.icon) }
                    .buttonStyle(.borderless)
                    .help("Save attachment…")
                    .accessibilityLabel("Save \(attachment.name)")
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(inset, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
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

    private func saveAttachment(_ attachment: MailAttachment, data: Data? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do {
                if let data { try data.write(to: destination, options: .atomic) }
                else if let source = attachment.localURL { try Data(contentsOf: source).write(to: destination, options: .atomic) }
            }
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
            MessageLabelButton(message: syncedToolbarMessage, isSelected: runtime.readerPanel?.action == .labels) {
                toggleActionPanel(.labels)
            }

            let starred = message?.isStarred == true
            let starTitle = starred ? "Remove Star" : "Star Message"
            Button {
                if let selected = toolbarMessage {
                    store.toggleStar(selected.id)
                    if !selected.isStarred { starKick += 1 }
                }
            } label: {
                PostmereLabel(starTitle, symbol: starred ? "star.fill" : "star", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(starred ? palette.accentInk : PostmereTheme.icon)
                    .actionKick(.star, trigger: starKick, enabled: !reduceMotion)
            }
            .help(starTitle)
            .accessibilityValue(starred ? "On" : "Off")
            .disabled(message == nil)

            let snoozeTitle = message?.workflow.snoozedUntil == nil ? "Snooze Conversation…" : "Reschedule Snooze…"
            Button { toggleActionPanel(.snooze) } label: {
                PostmereLabel(snoozeTitle, symbol: "moon.zzz", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(runtime.readerPanel?.action == .snooze ? palette.accentInk : PostmereTheme.icon)
                    .actionKick(.snooze, trigger: snoozeKick, enabled: !reduceMotion)
            }
            .help(snoozeTitle)
            .accessibilityValue(runtime.readerPanel?.action == .snooze ? "Shown" : "Hidden")
            .disabled(message == nil)


            Button {
                if store.selectedMessage?.mailbox == .trash {
                    store.restoreSelected()
                } else if returnsToInbox {
                    store.moveSelected(to: .inbox)
                } else { store.archiveSelected() }
            } label: {
                PostmereLabel(moveActionTitle, symbol: returnsToInbox ? "tray.and.arrow.down" : "archivebox", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(PostmereTheme.icon)
                    .actionKick(returnsToInbox ? .restore : .archive, trigger: archiveKick, enabled: !reduceMotion)
            }
            .help(returnsToInbox ? moveActionTitle : "\(moveActionTitle) · ⇧⌘A")
            .disabled(store.selectedMessage == nil || (store.selectedMessage?.mailbox != .trash && !store.canMoveSelected(to: returnsToInbox ? .inbox : .archive)))

            Button { store.deleteSelected() } label: {
                PostmereLabel("Move to Trash", symbol: "trash", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(PostmereTheme.icon)
                    .trashWobble(trigger: trashKick, enabled: !reduceMotion)
            }
                .help("Move to Trash · ⌘Delete")
                .disabled(!store.canMoveSelected(to: .trash))
        }
        if !compactToolbar { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if showsSenderDetails { closeSenderDetails() }
                else if let message = store.selectedMessage { selectSenderDetails(message) }
            } label: {
                PostmereLabel("Sender details", symbol: "sidebar.right", size: 17)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(showsSenderDetails ? palette.accentInk : PostmereTheme.icon)
            }
            .help(showsSenderDetails ? "Hide sender details" : "Show sender details")
            .accessibilityValue(showsSenderDetails ? "Shown" : "Hidden")
            .disabled(store.selectedMessage == nil || store.selectedMessageIDs.count > 1)

            Button(action: summarizeConversation) {
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
            if store.selectedMessageIDs.count <= 1 && message.allowsWorkflowActions {
                spamCheckAction(message)
                Button(message.needsReply ? "Mark Conversation Done" : "Needs Reply") { store.setNeedsReply(!message.needsReply, for: message.id) }
                if toolbarMessage == nil {
                    Button("Snooze…") { runtime.openReaderPanel(.snooze) }
                }
                Button("Follow-up Reminder…") { runtime.openReaderPanel(.followUp) }
                Button("Private Note…") { runtime.openReaderPanel(.privateNote) }
                if message.backendMessageID != nil {
                    Button("Share Conversation…") { runtime.openReaderPanel(.share) }
                    Button("Suggest Next Steps…") { runtime.openReaderPanel(.suggestions) }
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
                            runtime.openReaderPanel(.calendar(suggestion.eventDraft(title: message.subject)))
                        }
                    }
                }
            }
            Button("Message Details") { runtime.openReaderPanel(.details) }.disabled(store.selectedMessageIDs.count > 1)
        }
    }

    @ViewBuilder private func spamCheckAction(_ message: MailMessage) -> some View {
        if MailSpamChecks.canCheck(message, session: runtime.backend) {
            if case .checking? = runtime.spamChecks.phase(for: message, session: runtime.backend) {
                Button("Checking for Spam…", systemImage: "shield") {}.disabled(true)
            } else {
                Button("Check for Spam", systemImage: "shield") {
                    if store.selectedConversation.count > 1 { revealMessageInThread(message.id) }
                    runtime.spamChecks.check(message, session: runtime.backend)
                }
            }
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
        return message.mailbox == .archive || message.mailbox.isJunkOrTrash
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

private nonisolated struct ThreadGroupAnchor: Hashable, Sendable { let firstMessage: UUID }

private struct ThreadMessageGroup: Identifiable {
    let id: ThreadGroupAnchor
    let messages: ArraySlice<MailMessage>

    static func groups(in thread: [MailMessage], individualTargets: Bool) -> [Self] {
        guard thread.count > 1 else { return [] }
        // Keep the next few message bodies warm without starting an entire long thread at once.
        // Source links need an addressable lazy scroll target for the exact message.
        let count = individualTargets ? 1 : 6
        return stride(from: 0, to: thread.count, by: count).map { start in
            Self(id: ThreadGroupAnchor(firstMessage: thread[start].id),
                 messages: thread[start..<min(start + count, thread.count)])
        }
    }
}

private struct ProgressiveThreadGroup<Content: View>: View {
    let group: ThreadMessageGroup
    let expanded: Set<UUID>
    let priorityID: UUID
    @ViewBuilder var content: (MailMessage, Bool) -> Content
    @State private var prepared: Set<UUID> = []

    var body: some View {
        let articles = group.messages.compactMap { expanded.contains($0.id) && $0.bodyHTML != nil ? $0.id : nil }
        let firstArticle = articles.contains(priorityID) ? priorityID : articles.first
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(group.messages) { entry in
                content(entry, entry.id == firstArticle || prepared.contains(entry.id))
            }
        }
        .task(id: articles) {
            prepared.formIntersection(articles)
            if let firstArticle { prepared.insert(firstArticle) }
            for id in articles where !prepared.contains(id) {
                // Space out WebKit startup so subsequent bodies are ready before the reader reaches them.
                do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
                prepared.insert(id)
            }
        }
    }
}

private extension EnvironmentValues {
    @Entry var hoveringMailMessage = false
}

private struct HoverableMailMessage<Content: View>: View {
    @ViewBuilder var content: (Binding<Int>) -> Content
    @State private var blockedTrackerCount = 0

    var body: some View {
        content($blockedTrackerCount)
            .modifier(MailMessageHover())
    }
}

private struct MailMessageHover: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .environment(\.hoveringMailMessage, isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private struct HoverResponseControls<Content: View>: View {
    @Environment(\.mailboxInset) private var inset
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
            .background(inset, in: Capsule())
            .foregroundStyle(PostmereTheme.icon)
            .fixedSize()
            .focused($hasFocus)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
    }
}
