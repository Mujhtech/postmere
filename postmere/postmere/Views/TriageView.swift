import SwiftUI

/// A focused, one-conversation-at-a-time pass over the mail window.
struct TriageView: View {
    let session: TriageSession
    let store: MailStore
    let close: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MailRuntime.self) private var runtime
    @FocusState private var focused: Bool
    @State private var choosingSnooze = false
    @State private var expandedEarlier: Set<UUID> = []
    @State private var unsubscribing: MailMessage?
    /// Set when the unsubscribe sheet archived or blocked, so the card moves on.
    @State private var unsubscribeHandled = false

    private var canUnsubscribe: Bool { message.map { MailUnsubscribeService.options(for: $0).isAvailable } ?? false }
    @AppStorage("readingFontSize") private var readingFontSize = 14.0
    @AppStorage(MailReadingFont.preference) private var readingFont = MailReadingFont.original

    private var suggestion: TriageSuggestion? { message.flatMap { runtime.triageSuggestions.suggestion(for: $0) } }

    /// The key a suggestion maps to. Unsubscribe suggests archiving for now.
    private var suggestedDecision: TriageSession.Decision? {
        switch suggestion?.action {
        case .reply: .reply
        case .needsReply: .needsReply
        case .archive: .archive
        case .unsubscribe: canUnsubscribe ? .unsubscribe : .archive
        case .snooze: suggestion?.snoozeDate == nil ? nil : .snooze
        case .keep: .skip
        case nil: nil
        }
    }

    private var message: MailMessage? {
        session.currentID.flatMap { id in store.messages.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if session.showsBatch {
                    batchCard
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: session.isReturning ? .triageExit(.archive) : .triageArrival,
                            removal: .triageExit(session.exit)))
                } else if session.isFinished {
                    TriageSummary(session: session, close: close)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if let message {
                    card(message)
                        .id(message.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: session.isReturning ? .triageExit(session.exit) : .triageArrival,
                            removal: .triageExit(session.exit)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            if !session.isFinished { actionBar }
        }
        .background(PostmereTheme.paper)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down, action: handleKey)
        .onChange(of: session.currentID, initial: true) { _, id in
            choosingSnooze = false
            expandedEarlier = []
            // Opening the conversation loads its body and marks it read, as reading would.
            if let id, let message = store.messages.first(where: { $0.id == id }) { store.select(message) }
        }
        .task(id: session.index) {
            // Keep suggestions a few cards ahead of the one on screen.
            let upcoming = session.ids.dropFirst(session.index).prefix(12)
                .compactMap { id in store.messages.first { $0.id == id } }
            await runtime.triageSuggestions.prefetch(upcoming, session: runtime.backend)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Triage")
        .sheet(item: $unsubscribing, onDismiss: { if let message = unsubscribing ?? self.message { finishUnsubscribe(message) } }) { message in
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
                if archive { _ = store.moveMessages([message.id], to: .archive) }
                if block {
                    store.saveSenderRule(SenderRule(email: message.senderEmail, account: message.account,
                                                    route: .blocked, providerAccountEmail: message.providerAccountEmail),
                                         applyToExisting: false)
                }
                unsubscribeHandled = archive || block
            }, session: runtime.backend, archiveByDefault: true)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                PostmereIcon("xmark", size: 11).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(PostmereTheme.rule.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Leave triage · Esc")
            .accessibilityLabel("Leave triage")
            VStack(alignment: .leading, spacing: 1) {
                Text("Triage").font(.system(size: 13, weight: .semibold))
                Text(session.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.isFinished ? "Done" : "\(session.position + 1) of \(session.total)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(session.index)))
            GeometryReader { proxy in
                Capsule().fill(PostmereTheme.rule.opacity(0.6))
                    .overlay(alignment: .leading) {
                        Capsule().fill(palette.accent).frame(width: proxy.size.width * session.progress)
                    }
            }
            .frame(width: 120, height: 4)
            .animation(.spring(duration: 0.45, bounce: 0.1), value: session.progress)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Card

    private func card(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 40,
                                 verifiedMark: store.displayedSenderMark(for: message))
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.sender).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(message.senderEmail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(message.sentAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(message.displaySubject)
                .font(.system(size: 24, weight: .medium, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            if let suggestion {
                suggestionLine(suggestion)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
            if !message.attachments.isEmpty {
                Label("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            Divider().padding(.vertical, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let thread = conversation(for: message)
                    // Earlier messages in the thread, newest last, collapsed until opened.
                    ForEach(thread.dropLast()) { earlier in
                        earlierMessage(earlier)
                    }
                    if thread.count > 1, let latest = thread.last {
                        HStack(spacing: 6) {
                            Text(latest.sender.isEmpty ? latest.senderEmail : latest.sender)
                                .font(.system(size: 12, weight: .semibold))
                            Text(latest.sentAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    messageBody(thread.last ?? message)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .padding(28)
        .frame(maxWidth: 680, maxHeight: 560, alignment: .topLeading)
        .background(PostmereTheme.paper, in: .rect(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 28, y: 12)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        .padding(.vertical, 12)
    }

    /// "Suggested: Archive — Receipt, nothing to do", with priority and any deadline.
    private func suggestionLine(_ suggestion: TriageSuggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(suggestion.priority.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(suggestion.priority == .needsYou ? palette.accentInk : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background((suggestion.priority == .needsYou ? palette.accentInk : Color.secondary).opacity(0.12), in: .capsule)
            HStack(spacing: 4) {
                PostmereIcon(suggestion.source == .history ? "clock" : "sparkles", size: 11)
                Text(verbatim: suggestion.reason)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            if let deadline = suggestion.deadlineDate {
                Text("Due \(deadline.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PostmereTheme.destructiveInk)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Suggestion: \(suggestion.reason)")
    }

    // MARK: Batch

    private var batchMessages: [MailMessage] {
        session.batch.compactMap { id in store.messages.first { $0.id == id } }
    }

    /// Bulk mail as one card: what is in it, and one decision for all of it.
    private var batchCard: some View {
        let items = batchMessages
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PostmereIcon("tray.full", size: 18)
                    .foregroundStyle(palette.accentInk)
                    .frame(width: 40, height: 40)
                    .background(palette.accentInk.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(items.count) newsletters and notifications")
                        .font(.system(size: 20, weight: .medium, design: .serif))
                    Text("Postmere suggests archiving these together. You can still go through them one by one.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(items.prefix(7)) { message in
                    HStack(spacing: 10) {
                        ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 22, verifiedMark: nil)
                        Text(message.sender).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            .frame(width: 150, alignment: .leading)
                        Text(message.displaySubject).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if items.count > 7 {
                    Text("and \(items.count - 7) more").font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.leading, 32)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 680, alignment: .topLeading)
        .background(PostmereTheme.paper, in: .rect(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 28, y: 12)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func archiveBatch() {
        let items = batchMessages.filter { store.canMoveMessage($0, to: .archive) }
        guard !items.isEmpty else { session.reviewBatch(); return }
        for message in items { runtime.triageSuggestions.record(.archive, for: message, session: runtime.backend) }
        _ = store.moveMessages(Set(items.map(\.id)), to: .archive)
        session.archiveBatch()
    }

    /// The conversation as the reader shows it, oldest first.
    private func conversation(for message: MailMessage) -> [MailMessage] {
        let thread = store.selectedMessage?.id == message.id ? store.selectedConversation : [message]
        let visible = thread.filter { !$0.isDraft && !$0.mailbox.isJunkOrTrash }
        return (visible.isEmpty ? [message] : visible).sorted { $0.sentAt < $1.sentAt }
    }

    /// The same renderers as the reader: HTML, formatted or plain text with links.
    @ViewBuilder private func messageBody(_ message: MailMessage) -> some View {
        Group {
            if let html = message.receivedHTML {
                HTMLMessageBody(html: html, paragraphs: message.paragraphs, fontSize: readingFontSize, readingFont: readingFont)
            } else {
                RichTextMessageBody(rtf: message.bodyRTF, paragraphs: message.paragraphs.isEmpty ? [message.displayPreview] : message.paragraphs,
                                    fontSize: readingFontSize, readingFont: readingFont)
            }
        }
        .textSelection(.enabled)
        .id(message.id)
    }

    private func earlierMessage(_ message: MailMessage) -> some View {
        let expanded = expandedEarlier.contains(message.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if expanded { expandedEarlier.remove(message.id) } else { expandedEarlier.insert(message.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    PostmereIcon(expanded ? "chevron.down" : "chevron.right", size: 10).foregroundStyle(.tertiary)
                    Text(message.isOutgoing ? "You" : (message.sender.isEmpty ? message.senderEmail : message.sender))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if !expanded {
                        Text(message.displayPreview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(message.sentAt, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                messageBody(message)
                    .padding(.leading, 18)
                    .transition(.opacity)
            }
            Divider()
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        Group {
            if session.showsBatch {
                HStack(spacing: 8) {
                    TriageKey(title: "Archive all", key: "E", symbol: "archivebox", suggested: true) { archiveBatch() }
                    TriageKey(title: "One by one", key: "␣", symbol: "chevron.right") { session.reviewBatch() }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            } else if choosingSnooze {
                HStack(spacing: 8) {
                    Text("Snooze until").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(Array(snoozeChoices.enumerated()), id: \.offset) { index, choice in
                        TriageKey(title: choice.title, key: "\(index + 1)") { snooze(until: choice.date) }
                    }
                    TriageKey(title: "Cancel", key: "esc") { choosingSnooze = false }
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            } else {
                HStack(spacing: 8) {
                    TriageKey(title: "Archive", key: "E", symbol: "archivebox", suggested: suggestedDecision == .archive) { act(.archive) }
                    if canUnsubscribe {
                        TriageKey(title: "Unsubscribe", key: "U", symbol: "bell.slash",
                                  suggested: suggestedDecision == .unsubscribe) { startUnsubscribe() }
                    }
                    TriageKey(title: "Trash", key: "#", symbol: "trash", destructive: true) { act(.trash) }
                    TriageKey(title: suggestedDecision == .snooze ? snoozeTitle : "Snooze", key: "S", symbol: "moon.zzz",
                              suggested: suggestedDecision == .snooze) { snoozeOrChoose() }
                    TriageKey(title: "Reply", key: "R", symbol: "arrowshape.turn.up.left", suggested: suggestedDecision == .reply) { act(.reply) }
                    TriageKey(title: reminderDate.map { "Needs reply · remind \($0.formatted(.dateTime.weekday(.abbreviated)))" } ?? "Needs reply",
                              key: "H", symbol: "bell", suggested: suggestedDecision == .needsReply) { act(.needsReply) }
                    TriageKey(title: "Skip", key: "␣", symbol: "chevron.right", suggested: suggestedDecision == .skip) { act(.skip) }
                    TriageKey(title: "Undo", key: "Z", symbol: "arrow.uturn.backward") { undo() }
                        .disabled(session.decisions.isEmpty)
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.22), value: choosingSnooze)
    }

    private var snoozeChoices: [(title: String, date: Date)] {
        let calendar = Calendar.current
        let now = Date.now
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3 * 3600)
        let laterToday = evening > now.addingTimeInterval(3600) ? evening : now.addingTimeInterval(3 * 3600)
        let tomorrow = calendar.date(bySettingHour: 8, minute: 0, second: 0,
                                     of: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ?? now
        let nextWeek = calendar.date(bySettingHour: 8, minute: 0, second: 0,
                                     of: calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? now) ?? now
        return [("Later today", laterToday), ("Tomorrow", tomorrow), ("Next week", nextWeek)]
    }

    /// 9 AM on a suggested deadline still ahead, for a follow-up reminder.
    private var reminderDate: Date? {
        guard let day = suggestion?.deadlineDate,
              let date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day), date > .now else { return nil }
        return date
    }

    /// "Snooze to Dec 10" when a date is suggested.
    private var snoozeTitle: String {
        guard let date = suggestion?.snoozeDate else { return "Snooze" }
        return "Snooze to \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// S snoozes straight to a suggested date, or offers the choices.
    private func snoozeOrChoose() {
        if suggestedDecision == .snooze, let date = suggestion?.snoozeDate {
            snooze(until: date)
        } else {
            withAnimation(.snappy) { choosingSnooze = true }
        }
    }

    /// Return accepts the suggestion.
    private func acceptSuggestion() -> Bool {
        guard let decision = suggestedDecision else { return false }
        switch decision {
        case .snooze: snoozeOrChoose()
        case .unsubscribe: startUnsubscribe()
        default: act(decision)
        }
        return true
    }

    private func startUnsubscribe() {
        guard canUnsubscribe, let message else { return }
        unsubscribeHandled = false
        unsubscribing = message
    }

    /// The sheet has closed: move on only if it archived or blocked.
    private func finishUnsubscribe(_ message: MailMessage) {
        focused = true
        guard unsubscribeHandled, session.currentID == message.id else { return }
        runtime.triageSuggestions.record(.unsubscribe, for: message, session: runtime.backend)
        session.decide(.unsubscribe)
    }

    private func act(_ decision: TriageSession.Decision) {
        guard let message else { return }
        runtime.triageSuggestions.record(decision, for: message, session: runtime.backend)
        switch decision {
        case .archive:
            guard store.canMoveMessage(message, to: .archive) else { return }
            store.moveMessage(message.id, to: .archive)
        case .trash:
            guard store.canMoveMessage(message, to: .trash) else { return }
            store.moveMessage(message.id, to: .trash)
        case .reply:
            store.beginReplyAll(message)
        case .needsReply:
            store.setNeedsReply(true, for: message.id)
            // A stated deadline becomes a reminder that morning.
            if let reminderDate { store.setFollowUp(message.id, at: reminderDate, onlyIfNoReply: true) }
        case .snooze, .skip, .unsubscribe:
            break
        }
        session.decide(decision)
    }

    private func snooze(until date: Date) {
        guard let message else { return }
        runtime.triageSuggestions.record(.snooze, for: message, session: runtime.backend)
        store.snoozeMessage(message.id, until: date)
        choosingSnooze = false
        session.decide(.snooze)
    }

    private func undo() {
        if session.undoBatch() != nil {
            store.undoLastMove()
            return
        }
        guard let last = session.undo() else { return }
        switch last.decision {
        case .archive, .trash, .unsubscribe: store.undoLastMove()
        case .snooze: store.unsnoozeMessage(last.id)
        case .needsReply:
            store.setNeedsReply(false, for: last.id)
            store.clearFollowUp(last.id)
        case .reply, .skip: break
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            if choosingSnooze { choosingSnooze = false } else { close() }
            return .handled
        }
        if session.isFinished {
            if press.key == .return { close(); return .handled }
            if press.characters.lowercased() == "z" { undo(); return .handled }
            return .ignored
        }
        if session.showsBatch {
            switch press.key {
            case .return: archiveBatch(); return .handled
            case .space, .rightArrow: session.reviewBatch(); return .handled
            default: break
            }
            if press.characters.lowercased() == "e" { archiveBatch(); return .handled }
            return .ignored
        }
        if choosingSnooze, let digit = Int(press.characters), (1...snoozeChoices.count).contains(digit) {
            snooze(until: snoozeChoices[digit - 1].date)
            return .handled
        }
        if press.key == .return, !choosingSnooze { return acceptSuggestion() ? .handled : .ignored }
        if press.key == .space || press.key == .rightArrow { act(.skip); return .handled }
        if press.key == .leftArrow || (press.characters.lowercased() == "z" && press.modifiers.isEmpty) { undo(); return .handled }
        if press.modifiers.contains(.command), press.characters.lowercased() == "z" { undo(); return .handled }
        if press.key == .delete { act(.trash); return .handled }
        switch press.characters.lowercased() {
        case "e": act(.archive)
        case "#": act(.trash)
        case "s": snoozeOrChoose()
        case "r": act(.reply)
        case "h": act(.needsReply)
        case "u": startUnsubscribe()
        default: return .ignored
        }
        return .handled
    }
}

// MARK: - Pieces

private struct TriageKey: View {
    let title: String
    let key: String
    var symbol: String?
    var destructive = false
    /// The suggested choice: accent-outlined, and Return also chooses it.
    var suggested = false
    let action: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    PostmereIcon(symbol, size: 13)
                        .foregroundStyle(destructive ? PostmereTheme.destructiveInk : palette.accentInk)
                }
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(suggested ? "\(key) ↩" : key)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(suggested ? palette.accentInk : .secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(suggested ? palette.accentInk.opacity(0.12) : PostmereTheme.rule.opacity(0.7), in: .capsule)
            }
            .padding(.leading, symbol == nil ? 12 : 10)
            .padding(.trailing, 7)
            .frame(height: 32)
            .background(hovering || suggested ? palette.selectionFill : PostmereTheme.rule.opacity(0.25), in: .capsule)
            .overlay(Capsule().strokeBorder(suggested ? palette.accentInk.opacity(0.55) : .clear, lineWidth: 1.5))
            .contentShape(.capsule)
        }
        .buttonStyle(TriageKeyStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.snappy(duration: 0.2), value: suggested)
        .help(suggested ? "\(title) · \(key) or Return (suggested)" : "\(title) · \(key)")
        .accessibilityHint(suggested ? "Suggested" : "")
    }
}

private struct TriageKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Shown when the queue is done: what was decided, and the way back.
private struct TriageSummary: View {
    let session: TriageSession
    let close: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(palette.accent.opacity(0.12)).frame(width: 72, height: 72)
                    .scaleEffect(drawn || reduceMotion ? 1 : 0.6)
                PostmereIcon("checkmark", size: 28).foregroundStyle(palette.accentInk)
                    .scaleEffect(drawn || reduceMotion ? 1 : 0.3)
                    .opacity(drawn || reduceMotion ? 1 : 0)
            }
            .padding(.bottom, 4)
            Text("All done").font(.system(size: 30, weight: .medium, design: .serif))
            Text("You went through \(session.conversationCount) conversation\(session.conversationCount == 1 ? "" : "s").")
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ForEach(TriageSession.Decision.allCases, id: \.self) { decision in
                    let count = session.count(of: decision)
                    if count > 0 {
                        VStack(spacing: 2) {
                            Text(count.formatted())
                                .font(.system(size: 20, weight: .semibold, design: .serif))
                                .monospacedDigit()
                            Text(decision.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 8)
            Button("Back to Inbox", action: close)
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 14)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.45).delay(0.1)) { drawn = true }
        }
    }
}

// MARK: - Motion

private struct TriageCardMotion: ViewModifier {
    let decision: TriageSession.Decision
    let progress: Double

    func body(content: Content) -> some View {
        let p = progress
        switch decision {
        case .archive, .unsubscribe:
            content.scaleEffect(1 - 0.12 * p, anchor: .bottom).offset(y: 90 * p).opacity(1 - p)
        case .trash:
            content
                .scaleEffect(1 - 0.08 * p, anchor: .bottom)
                .rotation3DEffect(.degrees(9 * p), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
                .offset(y: 60 * p)
                .blur(radius: 6 * p)
                .opacity(1 - p)
        case .snooze:
            content.scaleEffect(1 - 0.06 * p, anchor: .top).offset(y: -90 * p).blur(radius: 4 * p).opacity(1 - p)
        case .needsReply, .reply:
            content.rotationEffect(.degrees(3 * p), anchor: .bottomTrailing).offset(x: 160 * p).opacity(1 - p)
        case .skip:
            content.rotationEffect(.degrees(-3 * p), anchor: .bottomLeading).offset(x: -160 * p).opacity(1 - p)
        }
    }
}

private struct TriageArrival: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.94 + 0.06 * progress)
            .offset(y: 18 * (1 - progress))
            .opacity(progress)
    }
}

private extension AnyTransition {
    static func triageExit(_ decision: TriageSession.Decision) -> AnyTransition {
        .modifier(active: TriageCardMotion(decision: decision, progress: 1),
                  identity: TriageCardMotion(decision: decision, progress: 0))
    }

    static var triageArrival: AnyTransition {
        .modifier(active: TriageArrival(progress: 0), identity: TriageArrival(progress: 1))
    }
}
