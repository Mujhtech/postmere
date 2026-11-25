import QuickLook
import SwiftUI
import Translation

/// The selected conversation, edge to edge: subject, then each message separated by a rule,
/// newest expanded, with a reply bar pinned under the thumb.
struct MobileConversation: View {
    @Bindable var runtime: MailRuntime
    /// The mailbox owns navigation, including which column is visible after a fold.
    let onRemove: () -> Void
    @Environment(\.mobileToolbarVerticalEdge) private var verticalBarEdge
    @State private var expanded: Set<UUID> = []
    @State private var summary: MailConversationSummary?
    @State private var sheet: ReaderSheet?
    @State private var translates = false
    @State private var detectedDates: (source: MobileCalendarSuggestionSource, dates: [MailDateSuggestion])?
    /// From/To/Date for a single message, opened from the sender in the bar.
    @State private var showsDetails = false
    @State private var scrollTarget: UUID?
    @Environment(\.postmereAccent) private var palette
    private var store: MailStore { runtime.store }

    private enum ReaderSheet: Identifiable {
        case unsubscribe(MailMessage), sender(MailMessage), suggestions, share(MailMessage), tasks
        case details(MailMessage), activity(MailMessage), event(MailCalendarEventDraft)
        var id: String {
            switch self {
            case .share(let message): "share-\(message.id)"
            case .details(let message): "details-\(message.id)"
            case .activity(let message): "activity-\(message.id)"
            case .event(let draft): "event-\(draft.id)"
            case .suggestions: "suggestions"
            case .tasks: "tasks"
            case .unsubscribe(let message): "unsubscribe-\(message.id)"
            case .sender(let message): "sender-\(message.id)"
            }
        }
    }

    var body: some View {
        let thread = store.selectedConversation
        Group {
            if let lead = store.selectedMessage, !thread.isEmpty {
                let dateSource = MobileCalendarSuggestionSource(messageID: lead.id, subject: lead.subject, paragraphs: lead.paragraphs)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            header(lead, thread: thread)
                                .id(Self.headerAnchor)
                            ForEach(thread) { message in
                                MobileHairline()
                                let open = expanded.contains(message.id) || message.id == thread.last?.id
                                MobileMessageSection(message: message, runtime: runtime, isExpanded: open,
                                                     showsHeader: thread.count > 1,
                                                     showsDetails: thread.count > 1 ? nil : showsDetails,
                                                     onSender: { sheet = .sender(message) },
                                                     onUnsubscribe: { sheet = .unsubscribe(message) },
                                                     onActivity: { sheet = .activity(message) }) {
                                    withAnimation(.snappy) {
                                        if expanded.contains(message.id) { expanded.remove(message.id) }
                                        else { expanded.insert(message.id) }
                                    }
                                }
                                .id(message.id)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .onAppear { if thread.count > 1 { proxy.scrollTo(thread.last?.id, anchor: .top) } }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(MobileMotion.reveal) { proxy.scrollTo(target, anchor: .top) }
                        scrollTarget = nil
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if lead.mailbox != .outbox && !lead.isDraft {
                        VStack(spacing: 8) {
                            if canUseAI(lead), let incoming = thread.last(where: { !$0.isOutgoing && !$0.isDraft }),
                               thread.last(where: { !$0.isDraft })?.isOutgoing != true,
                               MailAIAssist.suggestsReplies(to: incoming) {
                                MobileQuickReplyStrip(message: incoming, conversation: thread, runtime: runtime)
                                    .id(incoming.id)
                            }
                            replyBar(lead)
                        }
                    }
                }
                .toolbar { actions(lead, dateSource: dateSource) }
                .task(id: dateSource, priority: .utility) {
                    let dates = await dateSource.suggestions()
                    guard !Task.isCancelled else { return }
                    detectedDates = (dateSource, dates)
                }
                .onChange(of: lead.id) { expanded = []; summary = nil; showsDetails = false }
                .task(id: summary?.requestID) { if let summary { await summary.load(session: runtime.backend) } }
                .translationPresentation(isPresented: $translates,
                                         text: (thread.last ?? lead).paragraphs.joined(separator: "\n\n"))
                .sheet(item: $sheet) { sheet in
                    switch sheet {
                    case .unsubscribe(let message): MobileUnsubscribeSheet(message: message, runtime: runtime)
                    case .suggestions: MobileSuggestionsSheet(runtime: runtime, messages: store.selectedConversation)
                    case .tasks: MobileActionItemsSheet(conversation: store.selectedConversation, runtime: runtime)
                    case .share(let message): MobileShareSheet(runtime: runtime, message: message)
                    case .details(let message): MobileMessageDetailsSheet(message: message, runtime: runtime)
                    case .activity(let message): MobileActivitySheet(message: message, runtime: runtime)
                    case .event(let draft): MobileEventEditor(draft: draft).ignoresSafeArea()
                    case .sender(let message):
                        MobileSenderSheet(message: message, runtime: runtime) { other in
                            store.select(other)
                        }
                    }
                }
            } else {
                MobileEmptyState(symbol: "envelope", title: "No message selected",
                                 message: "Choose a conversation to read it here.")
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Mobile.background)
        .navigationBarTitleDisplayMode(.inline)
        // Handoff: the same conversation opens on the Mac or another iPhone or iPad.
        .userActivity(MailContinuity.messageActivityType,
                      isActive: store.selectedMessage?.backendMessageID != nil) { activity in
            if let message = store.selectedMessage { MailContinuity.configure(activity, for: message) }
        }
    }

    private func header(_ message: MailMessage, thread: [MailMessage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if verticalBarEdge != nil { threadTitle(message, thread: thread) }
            Text(message.subject.isEmpty ? "No subject" : message.displaySubject)
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            // Only what isn't obvious: a mailbox other than the inbox, a thread, another account.
            if message.mailbox != .inbox || thread.count > 1 || MailAccount.allCases.count > 1 {
                HStack(spacing: 6) {
                    if message.mailbox != .inbox { tag(message.mailbox.title, symbol: message.mailbox.mobileSymbol) }
                    if thread.count > 1 { tag("\(thread.count) messages", symbol: "bubble.left.and.bubble.right") }
                    if MailAccount.allCases.count > 1 { tag(message.mailAccount.title, symbol: "person.crop.circle") }
                }
            }
            if let summary, summary.messageID == message.id {
                MobileSummaryCard(summary: summary) { withAnimation(MobileMotion.reveal) { self.summary = nil } }
                    .transition(MobileMotion.card)
            }
            if let quiet = MailNudges.waiting(in: thread).first {
                MobileNudgeCard(message: quiet, store: store)
            }
            if message.workflow.screeningState == .pending && message.mailbox != .junk && !message.isOutgoing {
                MobileNewSenderCard(message: message, store: store, onRemove: onRemove)
                    .transition(MobileMotion.card)
            }
            if let annotation = NeedsReplyAnnotation(selected: message, conversation: thread) {
                MobileNeedsReplyNote(annotation: annotation, inThread: thread.count > 1) {
                    withAnimation(.snappy) { _ = expanded.insert(annotation.messageID) }
                    scrollTarget = annotation.messageID
                } markDone: {
                    withAnimation(.snappy) {
                        for item in thread where item.needsReply { store.setNeedsReply(false, for: item.id) }
                    }
                }
                MobileWorkflowStrip(message: message, store: store, showsNeedsReply: false)
            } else {
                MobileWorkflowStrip(message: message, store: store)
            }
            if let item = store.outgoingQueue.first(where: { $0.id == message.id }) {
                MobileOutgoingStatus(store: store, item: item)
            }
        }
        .padding(.horizontal, Mobile.gutter)
        .padding(.top, 4)
        .padding(.bottom, 14)
        // Scoped here so the card animates however it was opened, including from the More menu.
        .animation(MobileMotion.reveal, value: summary?.id)
    }

    private func tag(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Mobile.raised, in: Capsule())
    }

    /// Archive, a wide reply target, and forward: the three things a phone does with mail.
    private func replyBar(_ message: MailMessage) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if store.canMoveMessage(message, to: .archive) {
                    circle("Archive", symbol: "archivebox") { move(message, to: .archive) }
                } else if store.canMoveMessage(message, to: .inbox) {
                    circle("Move to Inbox", symbol: "tray.and.arrow.down") { move(message, to: .inbox) }
                }
                Menu {
                    if store.hasReplyAllRecipients(for: message) {
                        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { store.beginReplyAll(message) }
                    }
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { store.beginForward(message) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Reply to \(replyName(message.sender))")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .contentShape(Capsule())
                } primaryAction: {
                    store.beginCompose(replyTo: message)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .disabled(MailAccount.sendingAccounts.isEmpty)
                .accessibilityLabel("Reply")
                .accessibilityHint("Touch and hold for Reply All and Forward")
                circle("Forward", symbol: "arrowshape.turn.up.right") { store.beginForward(message) }
                    .disabled(MailAccount.sendingAccounts.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func circle(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(title)
    }

    private func threadTitle(_ message: MailMessage, thread: [MailMessage]) -> some View {
        MobileThreadTitle(message: message, thread: thread, showsDetails: showsDetails) { avatar in
            if thread.count == 1 && !avatar {
                withAnimation(.snappy) { showsDetails.toggle() }
            } else if let sender = thread.last(where: { !$0.isOutgoing }) ?? (message.isOutgoing ? nil : message) {
                sheet = .sender(sender)
            }
        }
    }

    @ToolbarContentBuilder private func actions(_ message: MailMessage, dateSource: MobileCalendarSuggestionSource) -> some ToolbarContent {
        if verticalBarEdge == nil {
            ToolbarItem(placement: .topBarLeading) {
                threadTitle(message, thread: store.selectedConversation)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if canUseAI(message) {
                Button { summarize(message) } label: {
                    Image(systemName: "sparkles").font(Self.toolbarGlyph)
                }
                .symbolEffect(.bounce, value: summary?.id)
                .accessibilityLabel("Summarize")
            }
            Menu {
                Section {
                    if canUseAI(message) {
                        Button("Summarize", systemImage: "sparkles") { summarize(message) }
                        Button("Suggest Next Steps", systemImage: "wand.and.stars") { sheet = .suggestions }
                        Button("Check for Spam", systemImage: "shield") {
                            runtime.spamChecks.check(message, session: runtime.backend)
                        }
                    }
                    Button("Translate", systemImage: "translate") { translates = true }
                    if MailUnsubscribeService.options(for: message).isAvailable {
                        Button("Unsubscribe…", systemImage: "hand.wave") { sheet = .unsubscribe(message) }
                    }
                    if !message.isOutgoing {
                        Button("About Sender", systemImage: "person.crop.circle") { sheet = .sender(message) }
                    }
                    if let detectedDates, detectedDates.source == dateSource, !detectedDates.dates.isEmpty {
                        Menu("Add to Calendar", systemImage: "calendar.badge.plus") {
                            ForEach(detectedDates.dates) { date in
                                Button(date.matchedText) { sheet = .event(date.eventDraft(title: message.displaySubject)) }
                            }
                        }
                    }
                    if canUseAI(message) {
                        Button("Find To-Dos", systemImage: "checklist") { sheet = .tasks }
                    }
                    Button("Message Details", systemImage: "info.circle") { sheet = .details(message) }
                    Button("Print", systemImage: "printer") { MailPrintDocument.present(message) }
                    if message.hasTrackedActivity {
                        Button("Activity", systemImage: "eye") { sheet = .activity(message) }
                    }
                    if message.mailAccount.remote?.scope == runtime.backend.scope, message.providerThreadID != nil {
                        Button("Share with Team…", systemImage: "person.2") { sheet = .share(message) }
                    }
                }
                if let actions = runtime.plugins.plugins(for: message)?.actions, !actions.isEmpty {
                    Section {
                        ForEach(actions) { action in
                            Button(action.title, systemImage: action.icon) {
                                runtime.plugins.perform(action, message: message, session: runtime.backend)
                            }
                        }
                    }
                }
                MobileMessageMenu(message: message, store: store, includesReply: false, onRemove: onRemove)
            } label: {
                Image(systemName: "ellipsis").font(Self.toolbarGlyph)
            }
            .accessibilityLabel("More")
        }
    }

    /// The same weight as the reply bar's buttons, so the top bar doesn't shout.
    private static let toolbarGlyph = Font.system(size: 15, weight: .medium)

    private func canUseAI(_ message: MailMessage) -> Bool {
        message.backendMessageID != nil && !message.isDraft && message.mailbox != .outbox
    }

    private func summarize(_ message: MailMessage) {
        let session = runtime.backend
        let sources = MailConversationSummary.sourceIDs(for: message, in: store.selectedConversation, session: session)
        if let current = summary, current.messageID == message.id, current.sourceIDs == sources,
           current.sessionID == session.realtimeGeneration {
            if case .failed = current.phase { current.start() }
            scrollTarget = Self.headerAnchor
            return
        }
        withAnimation(MobileMotion.reveal) {
            summary = MailConversationSummary(messageID: message.id, sessionID: session.realtimeGeneration, sourceIDs: sources)
        }
        // In a long thread the reader starts at the newest message, so bring the card into view.
        scrollTarget = Self.headerAnchor
    }

    private static let headerAnchor = UUID()

    /// A person's first name, or a short brand name whole ("Product Hunt", not "Product").
    private func replyName(_ sender: String) -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "sender" }
        return trimmed.count <= 16 ? trimmed : firstName(trimmed)
    }

    private func firstName(_ sender: String) -> String {
        let name = sender.split(separator: " ").first.map(String.init) ?? sender
        return name.isEmpty ? "sender" : name
    }

    private func move(_ message: MailMessage, to mailbox: Mailbox) {
        store.moveMessage(message.id, to: mailbox)
        onRemove()
    }
}

/// One message: a compact header, then the body across the full width of the phone.
private struct MobileMessageSection: View {
    let message: MailMessage
    let runtime: MailRuntime
    let isExpanded: Bool
    /// A single message's sender lives in the top bar instead.
    var showsHeader = true
    /// Set when the bar controls the details card.
    var showsDetails: Bool?
    let onSender: () -> Void
    let onUnsubscribe: () -> Void
    let onActivity: () -> Void
    let toggle: () -> Void
    @Environment(\.postmereAccent) private var palette
    @AppStorage("readingFontSize") private var fontSize = 14.0
    @AppStorage(MailReadingFont.preference) private var readingFont = MailReadingFont.original
    @State private var showsOwnDetails = false

    /// Phones read comfortably a few points above the Mac's default.
    private var bodySize: Double { fontSize + 3 }

    var body: some View {
        MobileCollapsingStack(spacing: 14) {
            if showsHeader {
                header
                    .padding(.horizontal, Mobile.gutter)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(isExpanded ? "Collapses this message" : "Expands this message")
            }
            if isExpanded {
                if showsDetails ?? showsOwnDetails {
                    details.padding(.horizontal, Mobile.gutter)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                MobileCollapsingStack(spacing: 10) {
                    MobileSpamCheck(message: message, runtime: runtime)
                    MobileVerificationCode(message: message)
                    MobileInvitations(message: message, runtime: runtime)
                    MobilePluginCards(message: message, runtime: runtime)
                    if MailUnsubscribeService.options(for: message).isAvailable {
                        Button(action: onUnsubscribe) {
                            Label("Unsubscribe", systemImage: "hand.wave")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    if message.hasTrackedActivity {
                        Button(action: onActivity) {
                            Label("Activity", systemImage: "eye")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Mobile.gutter)
                Group {
                    if let html = message.receivedHTML {
                        HTMLMessageBody(html: html, paragraphs: message.paragraphs, fontSize: bodySize, readingFont: readingFont)
                            .padding(.horizontal, 8)
                    } else {
                        RichTextMessageBody(rtf: message.bodyRTF, paragraphs: message.paragraphs,
                                            fontSize: bodySize, readingFont: readingFont)
                            .textSelection(.enabled)
                            .padding(.horizontal, Mobile.gutter)
                    }
                }
                if !message.attachments.isEmpty {
                    MobileAttachmentList(message: message).padding(.horizontal, Mobile.gutter)
                }
            }
        }
        .padding(.vertical, isExpanded ? 16 : 13)
    }

    private var header: some View {
        HStack(alignment: isExpanded ? .top : .center, spacing: 12) {
            ParticipantPhoto(address: message.senderEmail, name: message.sender, size: isExpanded ? 38 : 30,
                             verifiedMark: message.verifiedSenderMark)
                .onTapGesture { if isExpanded && !message.isOutgoing { onSender() } else { toggle() } }
                .accessibilityLabel("About \(message.sender)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.sender)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(isExpanded ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(message.sentAt.mobileListDate)
                        .font(Mobile.meta)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if isExpanded {
                    Button {
                        withAnimation(.snappy) { showsOwnDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(message.shortRecipients).lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(showsOwnDetails ? 180 : 0))
                        }
                        .font(Mobile.meta)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsOwnDetails ? "Hide details" : "Show details")
                } else {
                    Text(message.preview).font(Mobile.rowLine).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            detail("From", message.senderEmail.isEmpty ? message.sender : message.senderEmail)
            detail("To", message.toRecipients.joined(separator: ", "))
            if !message.ccRecipients.isEmpty { detail("Cc", message.ccRecipients.joined(separator: ", ")) }
            detail("Date", message.sentAt.formatted(date: .long, time: .shortened))
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .textSelection(.enabled)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.tertiary).frame(width: 38, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
        }
    }
}

/// Attachments open in Quick Look after downloading through the workspace.
private struct MobileAttachmentList: View {
    let message: MailMessage
    @Environment(MailRuntime.self) private var runtime
    @State private var loading: UUID?
    @State private var preview: URL?
    @State private var error: String?
    @State private var summarizing: MailAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.attachments) { attachment in
                Button {
                    open(attachment)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol(for: attachment.name))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if !attachment.detail.isEmpty {
                                Text(attachment.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if loading == attachment.id { ProgressView() }
                        else { Image(systemName: "arrow.down.circle").foregroundStyle(.tertiary) }
                    }
                    .padding(12)
                    .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loading != nil)
                .contextMenu {
                    Button("Open", systemImage: "eye") { open(attachment) }
                    if MailDocumentText.canSummarize(attachment), message.backendMessageID != nil {
                        Button("Summarize with AI", systemImage: "sparkles") { summarizing = attachment }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(PostmereTheme.destructiveInk) }
        }
        .quickLookPreview($preview)
        .sheet(item: $summarizing) { MobileDocumentSummarySheet(attachment: $0, message: message, runtime: runtime) }
    }

    private func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "jpg", "jpeg", "png", "heic", "gif", "webp": "photo"
        case "mov", "mp4", "m4v": "film"
        case "zip", "gz", "tar": "doc.zipper"
        case "ics": "calendar"
        default: "doc"
        }
    }

    private func open(_ attachment: MailAttachment) {
        loading = attachment.id
        error = nil
        Task {
            defer { loading = nil }
            do {
                let resolved = try await runtime.resolveAttachment(attachment, in: message)
                preview = resolved.localURL
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Needs reply, snooze, follow-up and the private note, each tappable to change.
private struct MobileWorkflowStrip: View {
    let message: MailMessage
    let store: MailStore
    var showsNeedsReply = true
    @Environment(MobilePresenter.self) private var presenter

    var body: some View {
        let workflow = message.workflow
        let needsReply = showsNeedsReply && message.needsReply
        VStack(alignment: .leading, spacing: 8) {
            if needsReply || workflow.snoozedUntil != nil || workflow.followUpAt != nil {
                HStack(spacing: 6) {
                    if needsReply {
                        chip("Needs reply", symbol: "arrowshape.turn.up.left.fill", tint: .orange) {
                            store.setNeedsReply(false, for: message.id)
                        }
                        .accessibilityHint("Marks this conversation done")
                    }
                    if let until = workflow.snoozedUntil {
                        chip(until.mobileScheduleLabel, symbol: "moon.zzz.fill", tint: .indigo) {
                            presenter.task = .snooze([message.id])
                        }
                    }
                    if let at = workflow.followUpAt {
                        chip(at.mobileScheduleLabel, symbol: "bell.fill", tint: .secondary) {
                            presenter.task = .followUp(message)
                        }
                    }
                }
            }
            if !workflow.privateNote.isEmpty {
                Button { presenter.task = .note(message) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                        Text(workflow.privateNote)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Private note: \(workflow.privateNote)")
                .accessibilityHint("Edits the note")
            }
        }
    }

    private func chip(_ text: String, symbol: String, tint: some ShapeStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Mobile.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The bar's centre: who the conversation is with, and who it's to (one message) or everyone in it (a thread).
private struct MobileThreadTitle: View {
    let message: MailMessage
    let thread: [MailMessage]
    let showsDetails: Bool
    /// True when the photo was tapped.
    let onTap: (_ avatar: Bool) -> Void

    /// The other side of the conversation: the sender, or the first recipient of your own mail.
    private var counterpart: (address: String, name: String) {
        if let other = thread.last(where: { !$0.isOutgoing }) ?? (message.isOutgoing ? nil : message) {
            return (other.senderEmail, other.sender)
        }
        let recipient = message.toRecipients.first ?? ""
        let name = recipient.split(separator: "<").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? recipient
        return (MailSenderDomain.email(in: recipient) ?? recipient, name)
    }

    /// "Haneefah, You" — each person once, in the order they joined the thread.
    private var participants: String {
        var names: [String] = []
        for entry in thread {
            let name = entry.isOutgoing ? "You" : (entry.sender.isEmpty ? entry.senderEmail : entry.sender)
            if !names.contains(name) { names.append(name) }
        }
        if names == ["You"], let recipient = message.toRecipients.first {
            let name = recipient.split(separator: "<").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? recipient
            names.insert(name, at: 0)
        }
        return names.joined(separator: ", ")
    }

    var body: some View {
        let single = thread.count == 1
        HStack(spacing: 9) {
            ParticipantPhoto(address: counterpart.address, name: counterpart.name, size: 32,
                             verifiedMark: message.isOutgoing ? nil : message.verifiedSenderMark)
                .onTapGesture { onTap(true) }
            VStack(alignment: .leading, spacing: 0) {
                Text(counterpart.name.isEmpty ? counterpart.address : counterpart.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(single ? "\(message.shortRecipients) · \(message.sentAt.mobileListDate)" : participants)
                        .lineLimit(1)
                    if single {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showsDetails ? 180 : 0))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        // The bar gives a leading item almost no width unless it asks for some.
        .frame(width: 180, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onTap(false) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(single ? (showsDetails ? "Hides details" : "Shows details") : "Shows sender details")
    }
}

extension MailMessage {
    /// "to me", "to Ada, Sam +2".
    fileprivate var shortRecipients: String {
        let own = Set(MailAccount.allCases.map { $0.email.lowercased() })
        let names = toRecipients.map { recipient -> String in
            let address = MailSenderDomain.email(in: recipient)?.lowercased() ?? recipient.lowercased()
            if own.contains(address) { return "me" }
            return recipient.split(separator: "<").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? recipient
        }
        let first = names.prefix(2).joined(separator: ", ")
        let extra = names.count + ccRecipients.count - min(names.count, 2)
        return names.isEmpty ? "No recipients" : "to \(first)" + (extra > 0 ? " +\(extra)" : "")
    }
}
