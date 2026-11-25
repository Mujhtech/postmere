import SwiftUI
import UIKit

/// One conversation at a time: swipe right to archive, left to skip, or pick an action.
/// Suggestions from the workspace say what each card probably needs and why.
struct MobileTriageScreen: View {
    let session: TriageSession
    let runtime: MailRuntime
    /// Only the visible pass presents the composer, so it never competes with Home's.
    var isActive = true
    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGSize = .zero
    @State private var choosingSnooze = false
    @State private var unsubscribing: MailMessage?

    private var store: MailStore { runtime.store }
    private var message: MailMessage? { session.currentID.flatMap { id in store.messages.first { $0.id == id } } }
    private var suggestion: TriageSuggestion? { message.flatMap { runtime.triageSuggestions.suggestion(for: $0) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress
                ZStack {
                    if session.showsBatch {
                        batchCard.transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                    } else if let message {
                        card(message)
                            .id(message.id)
                            .transition(cardTransition)
                    } else if session.isFinished {
                        finished.transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                if !session.isFinished && !session.showsBatch && message != nil { actions }
            }
            .aboveMobileTabBar()
            .background(Mobile.background)
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { close() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                        .disabled(session.decisions.isEmpty)
                }
            }
            .task(id: isActive ? session.index : nil) {
                guard isActive else { return }
                // Another prefetch may still be running; keep asking until this card has its suggestion.
                for _ in 0..<6 {
                    guard !Task.isCancelled else { return }
                    await prefetch()
                    if suggestion != nil || Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            .sheet(isPresented: $choosingSnooze) {
                MobileScheduleSheet(purpose: .snooze, initial: suggestion?.snoozeDate) { date, _ in snooze(until: date) }
            }
            .sheet(item: $unsubscribing, onDismiss: finishUnsubscribe) { message in
                MobileUnsubscribeSheet(message: message, runtime: runtime)
            }
            .fullScreenCover(isPresented: Binding(get: { store.isComposing && isActive }, set: { _ in })) {
                MobileComposer(runtime: runtime)
            }
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Mobile.raised)
                    Capsule().fill(palette.accent).frame(width: proxy.size.width * session.progress)
                }
            }
            .frame(height: 5)
            .animation(.snappy, value: session.progress)
            Text(session.isFinished ? "All done" : "\(min(session.position + 1, session.total)) of \(session.total)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Mobile.gutter)
        .padding(.top, 6)
    }

    // MARK: Cards

    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let edge: Edge = session.isReturning ? .leading : exitEdge(session.exit)
        return .asymmetric(insertion: session.isReturning ? .move(edge: edge).combined(with: .opacity)
                                                          : .scale(scale: 0.94).combined(with: .opacity),
                           removal: .move(edge: edge).combined(with: .opacity))
    }

    private func exitEdge(_ decision: TriageSession.Decision) -> Edge {
        switch decision {
        case .skip, .snooze: .leading
        case .needsReply, .reply: .top
        case .trash: .bottom
        default: .trailing
        }
    }

    private func card(_ message: MailMessage) -> some View {
        let threshold: CGFloat = 110
        return VStack(alignment: .leading, spacing: 10) {
            // Kept small so most of the card is the mail itself.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 26,
                                     verifiedMark: message.verifiedSenderMark)
                    Text(message.sender.isEmpty ? message.senderEmail : message.sender)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(message.sentAt.mobileListDate)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Text(message.displaySubject)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion { suggestionBanner(suggestion) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            ScrollView {
                Group {
                    if let html = message.receivedHTML {
                        // Touches go to the card so it can still be swiped and scrolled.
                        HTMLMessageBody(html: html, paragraphs: message.paragraphs, fontSize: 15, readingFont: .original)
                            .allowsHitTesting(false)
                    } else {
                        Text(readable(message))
                            .font(.system(size: 15))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Mobile.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Mobile.hairline) }
        .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
        .overlay(alignment: .topLeading) { swipeStamp(threshold: threshold) }
        .rotationEffect(.degrees(Double(drag.width) / 25), anchor: .bottom)
        .offset(x: drag.width, y: drag.height * 0.15)
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    let x = value.translation.width + value.predictedEndTranslation.width * 0.2
                    if x > threshold {
                        act(.archive)
                    } else if x < -threshold {
                        act(.skip)
                    }
                    withAnimation(.spring(duration: 0.35)) { drag = .zero }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Archive") { act(.archive) }
        .accessibilityAction(named: "Skip") { act(.skip) }
    }

    /// "Done" or "Skip" fades in as the card is dragged past the threshold.
    private func swipeStamp(threshold: CGFloat) -> some View {
        let right = drag.width > 0
        let amount = min(1, abs(drag.width) / threshold)
        return Label(right ? "Done" : "Skip", systemImage: right ? "checkmark" : "arrow.uturn.left")
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(right ? palette.accent : Color.gray, in: Capsule())
            .opacity(amount)
            .scaleEffect(0.8 + 0.2 * amount)
            .frame(maxWidth: .infinity, alignment: right ? .leading : .trailing)
            .padding(18)
            .allowsHitTesting(false)
    }

    private func suggestionBanner(_ suggestion: TriageSuggestion) -> some View {
        HStack(alignment: .top, spacing: 7) {
            // From your own past decisions, or from the assistant.
            Image(systemName: suggestion.source == .history ? "clock.arrow.circlepath" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.top, 2)
            let heading = Text("\(suggestion.priority.title) · \(title(for: suggestion.action))")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(palette.accent)
            let due = suggestion.deadlineDate.map {
                Text("  Due \($0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.orange)
            } ?? Text("")
            Text("\(heading)\(due)\(Text(suggestion.reason.isEmpty ? "" : "  " + suggestion.reason).font(.system(size: 12.5)).foregroundStyle(.secondary))")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func title(for action: TriageSuggestion.Action) -> String {
        switch action {
        case .reply: "Reply"
        case .needsReply: "Needs reply"
        case .archive: "Archive"
        case .snooze: suggestion?.snoozeDate.map { "Snooze to \($0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" } ?? "Snooze"
        case .unsubscribe: "Unsubscribe"
        case .keep: "Worth reading"
        }
    }

    private var batchCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 34))
                .foregroundStyle(palette.accent)
                .frame(width: 72, height: 72)
                .background(palette.accent.opacity(0.12), in: Circle())
            Text("\(session.batch.count) bulk messages")
                .font(.system(size: 24, weight: .bold))
            Text("Newsletters, notifications and receipts that probably don’t need you one by one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button {
                    store.moveMessages(Set(session.batch), to: .archive)
                    session.archiveBatch()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Text("Archive All").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                Button { session.reviewBatch() } label: {
                    Text("Review One by One").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(palette.accent)
                .symbolEffect(.bounce, value: session.isFinished)
            Text("Triage done").font(.system(size: 26, weight: .bold))
            Text("\(session.conversationCount) conversation\(session.conversationCount == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(TriageSession.Decision.allCases, id: \.self) { decision in
                    let count = session.count(of: decision)
                    if count > 0 {
                        HStack {
                            Text(decision.title)
                            Spacer()
                            Text(count, format: .number).fontWeight(.semibold).monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    }
                }
            }
            .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 8)
            Button { close() } label: {
                Text("Done").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 8)
        }
        .padding(24)
        .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    /// The message as prose: no bare links, tracking URLs or rows of symbols.
    private func readable(_ message: MailMessage) -> String {
        let link = /\(?\s*https?:\/\/\S+\s*\)?/
        var paragraphs: [String] = []
        for paragraph in message.paragraphs {
            let cleaned = paragraph.replacing(link, with: "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in line.contains(where: \.isLetter) }
                .joined(separator: "\n")
            if !cleaned.isEmpty, cleaned != message.sender { paragraphs.append(cleaned) }
            if paragraphs.count == 10 { break }
        }
        let text = paragraphs.joined(separator: "\n\n")
        return text.isEmpty ? message.preview : text
    }

    // MARK: Actions

    private var actions: some View {
        let suggested = suggestedDecision
        return VStack(spacing: 10) {
            if let suggested { acceptButton(suggested) }
            actionRow(suggested)
        }
    }

    /// The phone's Return key: one tap does what's suggested for this card.
    private func acceptButton(_ decision: TriageSession.Decision) -> some View {
        Button(action: acceptSuggestion) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text(acceptTitle(decision))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(palette.accent).interactive(), in: Capsule())
        .padding(.horizontal, 14)
        .accessibilityHint("Does the suggested action")
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func acceptTitle(_ decision: TriageSession.Decision) -> String {
        switch decision {
        case .archive: "Archive"
        case .unsubscribe: "Unsubscribe"
        case .snooze: suggestion?.snoozeDate.map { "Snooze to \($0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" } ?? "Snooze"
        case .reply: "Reply"
        case .needsReply: "Mark Needs Reply"
        case .skip: "Keep and Go On"
        case .trash: "Trash"
        }
    }

    private func acceptSuggestion() {
        guard let decision = suggestedDecision else { return }
        switch decision {
        case .snooze:
            if let date = suggestion?.snoozeDate { snooze(until: date) } else { choosingSnooze = true }
        case .unsubscribe:
            unsubscribing = message
        default:
            act(decision)
        }
    }

    private func actionRow(_ suggested: TriageSession.Decision?) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                action("Trash", symbol: "trash", decision: .trash, suggested: false) { act(.trash) }
                action("Snooze", symbol: "moon.zzz", decision: .snooze, suggested: suggested == .snooze) {
                    if let date = suggestion?.snoozeDate, suggested == .snooze { snooze(until: date) } else { choosingSnooze = true }
                }
                action("Needs reply", symbol: "arrowshape.turn.up.left.circle", decision: .needsReply,
                       suggested: suggested == .needsReply) { act(.needsReply) }
                if canUnsubscribe {
                    action("Unsubscribe", symbol: "hand.wave", decision: .unsubscribe, suggested: suggested == .unsubscribe) {
                        unsubscribing = message
                    }
                }
                action("Reply", symbol: "arrowshape.turn.up.left", decision: .reply, suggested: suggested == .reply) { act(.reply) }
                // The same size as the other actions; its colour marks it as the main one.
                Button { act(.archive) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(palette.accent).interactive(), in: Circle())
                .accessibilityLabel("Archive")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func action(_ title: String, symbol: String, decision: TriageSession.Decision, suggested: Bool,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(suggested ? palette.accent : .primary)
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(suggested ? .regular.tint(palette.accent.opacity(0.25)).interactive() : .regular.interactive(), in: Circle())
        .accessibilityLabel(title)
        .accessibilityValue(suggested ? "Suggested" : "")
    }

    private var canUnsubscribe: Bool { message.map { MailUnsubscribeService.options(for: $0).isAvailable } ?? false }

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
            if let day = suggestion?.deadlineDate,
               let date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day), date > .now {
                store.setFollowUp(message.id, at: date, onlyIfNoReply: true)
            }
        case .snooze, .skip, .unsubscribe:
            break
        }
        UIImpactFeedbackGenerator(style: decision == .skip ? .light : .medium).impactOccurred()
        session.decide(decision)
    }

    private func snooze(until date: Date) {
        guard let message else { return }
        runtime.triageSuggestions.record(.snooze, for: message, session: runtime.backend)
        store.snoozeMessage(message.id, until: date)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.decide(.snooze)
    }

    /// Moves on only when the unsubscribe sheet took the message out of the inbox.
    private func finishUnsubscribe() {
        guard let current = message, current.mailbox != .inbox else { return }
        runtime.triageSuggestions.record(.unsubscribe, for: current, session: runtime.backend)
        session.decide(.unsubscribe)
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

    private func prefetch() async {
        let upcoming = session.ids.dropFirst(session.index).prefix(12).compactMap { id in
            store.messages.first { $0.id == id }
        }
        await runtime.triageSuggestions.prefetch(Array(upcoming), session: runtime.backend)
    }

    private func close() {
        withAnimation(.snappy) { runtime.triage = nil }
    }
}
