import SwiftUI

/// One streamed review of a conversation: the assistant's overview arrives
/// first, then each validated suggestion, then the result validated as a whole.
///
/// Network chunks arrive in bursts. Received text and items are buffered and
/// revealed at a steady pace (catching up quickly when a backlog builds), so
/// the overview types fluidly and suggestions land one after another.
@MainActor @Observable
final class MailSuggestionRun {
    enum Phase: Equatable {
        case loading, consent, streaming, ready
        case failed(String, canRetry: Bool)
    }

    let sourceIDs: [UUID]
    private(set) var phase: Phase = .loading
    private(set) var settings: MailAISettings?
    /// Displayed text and items; the rest is still being revealed.
    private(set) var overview = ""
    private(set) var items: [MailAIItem] = []
    private(set) var result: MailAIResult?
    private(set) var requestID = UUID()
    private(set) var isRevealing = false
    private var pendingText = ""
    private var pendingItems: [MailAIItem] = []
    private var receivedItems = 0
    private var reveal: Task<Void, Never>?
    private var enablingStyleGuide: String?

    init(sourceIDs: [UUID]) { self.sourceIDs = sourceIDs }

    /// The caret shows while text is still arriving or being revealed.
    var isTyping: Bool { phase == .streaming && items.isEmpty && pendingItems.isEmpty || !pendingText.isEmpty }

    /// Restarts the run; the view's task observes `requestID`.
    func start(enabling: Bool = false) {
        reveal?.cancel()
        reveal = nil
        isRevealing = false
        enablingStyleGuide = enabling ? (settings?.styleGuide ?? "") : nil
        overview = ""
        pendingText = ""
        items = []
        pendingItems = []
        receivedItems = 0
        result = nil
        phase = .loading
        requestID = UUID()
    }

    func load(session: BackendSession) async {
        let current = requestID
        guard let generation = session.realtimeGeneration, session.scope != nil else {
            phase = .failed("Connect your workspace in Settings → Accounts to get suggestions.", canRetry: false)
            return
        }
        guard !sourceIDs.isEmpty else {
            phase = .failed("This conversation needs to sync before it can be reviewed.", canRetry: true)
            return
        }
        do {
            let settings: MailAISettings = if let style = enablingStyleGuide {
                try await session.request("PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: true, styleGuide: style))
            } else {
                try await session.request("GET", "/v1/ai/settings")
            }
            guard requestID == current, session.realtimeGeneration == generation else { return }
            self.settings = settings
            guard settings.available else {
                phase = .failed("Your workspace administrator needs to configure an AI provider.", canRetry: false)
                return
            }
            guard settings.enabled else { phase = .consent; return }
            phase = .streaming
            let result = try await session.suggest(messageIDs: sourceIDs, onDelta: { chunk in
                guard self.requestID == current else { throw CancellationError() }
                self.enqueue(text: chunk)
            }, onItem: { item in
                guard self.requestID == current else { throw CancellationError() }
                guard item.action != nil else { return }
                self.receivedItems += 1
                self.enqueue(item: item)
            })
            try Task.checkCancellation()
            guard requestID == current, session.realtimeGeneration == generation else { return }
            finish(with: result)
        } catch {
            guard !Task.isCancelled, requestID == current else { return }
            reveal?.cancel()
            pendingText = ""
            pendingItems = []
            withAnimation(.smooth) {
                items = []
                phase = .failed(error.localizedDescription, canRetry: (error as? BackendAIError)?.canRetry ?? true)
            }
        }
    }

    /// Reconciles what was streamed with the result validated as a whole.
    private func finish(with result: MailAIResult) {
        let final = result.items.filter { $0.action != nil }
        let shown = overview + pendingText
        if result.text.hasPrefix(shown) {
            pendingText += result.text.dropFirst(shown.count)
        } else {
            overview = ""
            pendingText = result.text
        }
        if receivedItems <= final.count {
            pendingItems += final.dropFirst(receivedItems)
        } else {
            items = []
            pendingItems = final
        }
        self.result = result
        withAnimation(.smooth(duration: 0.4)) { phase = .ready }
        startRevealing()
    }

    private func enqueue(text: String) {
        pendingText += text
        startRevealing()
    }

    private func enqueue(item: MailAIItem) {
        pendingItems.append(item)
        startRevealing()
    }

    private func startRevealing() {
        guard reveal == nil else { return }
        isRevealing = true
        reveal = Task { [weak self] in
            await self?.drain()
            self?.reveal = nil
            self?.isRevealing = false
        }
    }

    private func drain() async {
        // Text first, about one frame at a time, then each suggestion in turn.
        while !Task.isCancelled {
            if !pendingText.isEmpty {
                let count = max(2, pendingText.count / 10)
                let next = pendingText.prefix(count)
                overview += next
                pendingText.removeFirst(next.count)
                try? await Task.sleep(for: .milliseconds(16))
            } else if !pendingItems.isEmpty {
                let item = pendingItems.removeFirst()
                withAnimation(.spring(duration: 0.55, bounce: 0.18)) { items.append(item) }
                try? await Task.sleep(for: .milliseconds(140))
            } else {
                return
            }
        }
    }
}

/// Reader panel that reviews the open conversation and proposes next steps.
struct MailSuggestionsView: View {
    let runtime: MailRuntime
    let messages: [MailMessage]

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissReaderPanel) private var dismissReaderPanel
    @State private var run: MailSuggestionRun
    @State private var applied: [Int: () -> Void] = [:]
    @State private var dismissed: Set<Int> = []
    @State private var openError: String?

    init(runtime: MailRuntime, messages: [MailMessage]) {
        self.runtime = runtime
        self.messages = messages
        let scope = runtime.backend.scope
        let ids = Array(Set(messages.filter { $0.mailAccount.remote?.scope == scope }.compactMap(\.backendMessageID)))
        _run = State(initialValue: MailSuggestionRun(sourceIDs: Array(ids.prefix(30))))
    }

    private var cardAnimation: Animation { reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.35) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AgentStatus(run: run, messageCount: run.sourceIDs.count, onRerun: rerun)
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(palette.accentInk)
        .task(id: run.requestID) { await run.load(session: runtime.backend) }
    }

    private func rerun() {
        withAnimation(.smooth(duration: 0.3)) {
            applied = [:]
            dismissed = []
            run.start()
        }
    }

    @ViewBuilder private var content: some View {
        switch run.phase {
        case .consent:
            VStack(alignment: .leading, spacing: 10) {
                Text(run.settings?.dataNotice ?? "").font(.callout).foregroundStyle(.secondary)
                Button("Enable AI and Review") { run.start(enabling: true) }
                    .buttonStyle(.borderedProminent)
            }
            .transition(.opacity)
        case .failed(let message, let canRetry):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if canRetry { Button("Try Again", action: rerun).buttonStyle(AccentLinkStyle()) }
            }
            .transition(.opacity)
        case .loading, .streaming, .ready:
            if !run.overview.isEmpty {
                StreamingText(text: run.overview, isTyping: run.isTyping)
                    .transition(.opacity)
            }
            cards
            if run.phase == .ready && !run.isRevealing {
                footer.transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
    }

    // MARK: Suggestions

    @ViewBuilder private var cards: some View {
        let visible = run.items.indices.filter { !dismissed.contains($0) }
        if !visible.isEmpty {
            VStack(spacing: 10) {
                ForEach(visible, id: \.self) { index in
                    SuggestionCard(item: run.items[index],
                                   source: source(for: run.items[index]),
                                   isReady: run.phase == .ready && canApply(run.items[index]),
                                   isApplied: applied[index] != nil,
                                   onApply: { withAnimation(cardAnimation) { apply(index) } },
                                   onUndo: { withAnimation(cardAnimation) { undo(index) } },
                                   onDismiss: { withAnimation(cardAnimation) { _ = dismissed.insert(index) } },
                                   onOpenSource: { source in Task { await open(source) } })
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .cardEntrance,
                            removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
        } else if run.phase == .ready && !run.isRevealing {
            Label {
                Text("Nothing needs doing here. This conversation is in good shape.")
            } icon: {
                PostmereIcon("checkmark.circle", size: 15).foregroundStyle(palette.accentInk)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    private var pendingIndices: [Int] {
        run.items.indices.filter { applied[$0] == nil && !dismissed.contains($0) && canApply(run.items[$0]) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pendingIndices.count > 1 {
                Button(action: applyAll) {
                    Text("Apply All \(pendingIndices.count)")
                        .contentTransition(.numericText(value: Double(pendingIndices.count)))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            if let openError {
                Text(openError).font(.caption).foregroundStyle(PostmereTheme.destructiveInk)
            }
            Text("Suggestions can be wrong. Nothing changes until you apply it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// Applies each pending suggestion in turn, so the change ripples down the list.
    private func applyAll() {
        for (order, index) in pendingIndices.enumerated() {
            let animation = reduceMotion ? cardAnimation : cardAnimation.delay(Double(order) * 0.07)
            withAnimation(animation) { apply(index) }
        }
    }

    private func source(for item: MailAIItem) -> MailAISource? {
        guard let id = item.messageId ?? item.sourceIds.first else { return nil }
        return run.result?.sources.first { $0.id == id }
    }

    private func localMessage(for item: MailAIItem) -> MailMessage? {
        guard let targetID = item.messageId, item.sourceIds.contains(targetID) else { return nil }
        let scope = runtime.backend.scope
        return runtime.store.messages.first { $0.backendMessageID == targetID && $0.mailAccount.remote?.scope == scope }
    }

    private func canApply(_ item: MailAIItem) -> Bool {
        localMessage(for: item) != nil && (item.action != "follow_up" || item.dueAt != nil)
    }

    private func apply(_ index: Int) {
        let item = run.items[index]
        guard run.phase == .ready, applied[index] == nil, let message = localMessage(for: item) else { return }
        let store = runtime.store
        switch item.action {
        case "needs_reply":
            store.setNeedsReply(true, for: message.id)
            applied[index] = { store.setNeedsReply(message.needsReply, for: message.id) }
        case "archive":
            store.moveMessages([message.id], to: .archive)
            applied[index] = { store.moveMessages([message.id], to: message.mailbox) }
        case "follow_up":
            guard let date = item.dueAt else { return }
            store.setFollowUp(message.id, at: date, onlyIfNoReply: true)
            applied[index] = {
                if let previous = message.workflow.followUpAt {
                    store.setFollowUp(message.id, at: previous, onlyIfNoReply: message.workflow.followUpOnlyIfNoReply)
                } else {
                    store.clearFollowUp(message.id)
                }
            }
        default:
            return
        }
    }

    private func undo(_ index: Int) {
        applied.removeValue(forKey: index)?()
    }

    private func open(_ source: MailAISource) async {
        do {
            guard let identity = RemoteAccountRegistry.accounts.first(where: {
                $0.accountID == source.accountId && $0.scope == runtime.backend.scope
            }) else { throw BackendError.notConnected }
            let message = try await runtime.fetchProviderMessage(source.id, for: identity)
            runtime.store.selectAccount(message.account)
            runtime.store.selectedInboxSplitID = nil
            runtime.store.selectedMailbox = message.mailbox
            runtime.store.select(message)
            dismissReaderPanel?()
        } catch { openError = error.localizedDescription }
    }
}

// MARK: - Streaming text

/// Overview prose with a softly breathing caret while it is still being written.
private struct StreamingText: View {
    let text: String
    let isTyping: Bool

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !isTyping)) { context in
            let wave = (cos(context.date.timeIntervalSinceReferenceDate * .pi * 1.6) + 1) / 2
            let caret = Text(verbatim: isTyping ? " ▍" : "")
                .foregroundStyle(palette.accentInk.opacity(reduceMotion ? 0.8 : 0.25 + 0.75 * wave))
            Text("\(Text(verbatim: text))\(caret)")
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel(text)
    }
}

// MARK: - Agent status

/// A live orb and a step trail describing what the assistant is doing. Once
/// the review is done, the trail folds into a single line.
private struct AgentStatus: View {
    let run: MailSuggestionRun
    let messageCount: Int
    let onRerun: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate enum Step: Int, CaseIterable {
        case read, assess, propose
        var title: String {
            switch self {
            case .read: "Read the conversation"
            case .assess: "Work out what it needs"
            case .propose: "Propose next steps"
            }
        }
    }

    private var isWorking: Bool { run.phase == .loading || run.phase == .streaming || run.isRevealing }
    private var messagesLabel: String { "\(messageCount) message\(messageCount == 1 ? "" : "s")" }

    /// The step in progress; every earlier step is complete.
    private var activeStep: Step? {
        guard run.phase == .loading || run.phase == .streaming else { return nil }
        if !run.items.isEmpty { return .propose }
        return run.overview.isEmpty ? .read : .assess
    }

    private var headline: String {
        switch run.phase {
        case .loading: "Reading \(messagesLabel)…"
        case .streaming:
            switch activeStep {
            case .propose: "Proposing next steps…"
            case .assess: "Thinking it through…"
            default: "Reading \(messagesLabel)…"
            }
        case .ready:
            if run.isRevealing { "Proposing next steps…" }
            else if run.items.isEmpty { "All clear" }
            else { "\(run.items.count) next step\(run.items.count == 1 ? "" : "s") ready" }
        case .consent: "Review this conversation"
        case .failed: "Couldn’t finish the review"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentOrb(isWorking: isWorking, isDone: run.phase == .ready && !run.isRevealing)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assistant")
                        .font(.system(size: 10.5, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(palette.accentInk)
                    ZStack(alignment: .leading) {
                        Text(headline)
                            .font(.system(size: 14, weight: .semibold))
                            .id(headline)
                            .transition(reduceMotion ? .opacity : .push(from: .bottom))
                    }
                    .clipped()
                    .animation(.snappy(duration: 0.35), value: headline)
                }
                Spacer(minLength: 0)
                if !isWorking && run.phase != .consent {
                    Button(action: onRerun) { PostmereIcon("arrow.clockwise", size: 14) }
                        .buttonStyle(.borderless)
                        .help("Review again")
                        .accessibilityLabel("Review again")
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            Group {
                if run.phase == .loading || run.phase == .streaming {
                    trail.transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                } else if run.phase == .ready {
                    reviewed.transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: run.phase)
        .animation(.smooth(duration: 0.35), value: run.isRevealing)
        .accessibilityElement(children: .contain)
    }

    private var trail: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Step.allCases, id: \.self) { step in
                StepRow(step: step,
                        isDone: activeStep.map { step.rawValue < $0.rawValue } ?? false,
                        isActive: activeStep == step)
            }
        }
        .padding(.leading, 9)
        .overlay(alignment: .leading) {
            Rectangle().fill(PostmereTheme.rule).frame(width: 1).padding(.vertical, 8).padding(.leading, 15.5)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .bouncy(duration: 0.4), value: activeStep)
    }

    private var reviewed: some View {
        HStack(spacing: 6) {
            PostmereIcon("checkmark", size: 10).foregroundStyle(palette.accentInk)
            Text("Reviewed \(messagesLabel)")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.leading, 9)
    }
}

private struct StepRow: View {
    let step: AgentStatus.Step
    let isDone: Bool
    let isActive: Bool

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if isDone {
                    PostmereIcon("checkmark", size: 10)
                        .foregroundStyle(palette.accentInk)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else if isActive {
                    ProgressView().controlSize(.mini).transition(.opacity)
                } else {
                    Circle().strokeBorder(PostmereTheme.rule, lineWidth: 1.2).frame(width: 8, height: 8)
                        .transition(.opacity)
                }
            }
            .frame(width: 14, height: 14)
            Text(step.title)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? .primary : .secondary)
                .overlay {
                    if isActive && !reduceMotion { Shimmer(text: step.title) }
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : isActive ? "In progress" : "Pending")
    }
}

/// A band of the primary color sweeping across the active step's label.
private struct Shimmer: View {
    let text: String
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let x = -0.4 + t * 1.8
            LinearGradient(colors: [.clear, palette.accentInk.opacity(0.85), .clear],
                           startPoint: UnitPoint(x: x - 0.25, y: 0.5),
                           endPoint: UnitPoint(x: x + 0.25, y: 0.5))
                .mask(Text(text).font(.system(size: 12)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Breathes while working and gives one confirming pulse when the review is done.
private struct AgentOrb: View {
    let isWorking: Bool
    let isDone: Bool

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(palette.selectionFill)
            if isWorking && !reduceMotion {
                Circle()
                    .strokeBorder(palette.accentInk.opacity(0.5), lineWidth: 1.5)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring.scaleEffect(expanded ? 1.4 : 1).opacity(expanded ? 0 : 1)
                    } animation: { expanded in expanded ? .easeOut(duration: 1.3) : .linear(duration: 0) }
                    .transition(.opacity)
            }
            PostmereIcon(isDone ? "checkmark" : "sparkles", size: 15)
                .foregroundStyle(palette.accentInk)
                .id(isDone)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
        .frame(width: 32, height: 32)
        .keyframeAnimator(initialValue: 1.0, trigger: isDone) { orb, scale in
            orb.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(reduceMotion ? 1 : 1.16, duration: 0.18)
                SpringKeyframe(1, duration: 0.4, spring: .bouncy)
            }
        }
        .animation(.bouncy(duration: 0.4), value: isDone)
        .animation(.smooth, value: isWorking)
        .accessibilityHidden(true)
    }
}

// MARK: - Suggestion card

private struct CardEntrance: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
            .offset(y: (1 - progress) * 14)
            .blur(radius: (1 - progress) * 6)
    }
}

private extension AnyTransition {
    /// Rises slightly and comes into focus.
    static var cardEntrance: AnyTransition {
        .modifier(active: CardEntrance(progress: 0), identity: CardEntrance(progress: 1))
    }
}

private struct SuggestionCard: View {
    let item: MailAIItem
    let source: MailAISource?
    let isReady: Bool
    let isApplied: Bool
    let onApply: () -> Void
    let onUndo: () -> Void
    let onDismiss: () -> Void
    let onOpenSource: (MailAISource) -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.mailboxInset) private var inset
    @State private var hovering = false

    private var symbol: String {
        switch item.action {
        case "archive": "archivebox"
        case "follow_up": "bell"
        default: "arrowshape.turn.up.left"
        }
    }

    private var title: String {
        switch item.action {
        case "archive": "Archive this conversation"
        case "follow_up":
            if let due = item.dueAt {
                "Follow up \(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))"
            } else { "Set a follow-up" }
        default: "Add to Needs Reply"
        }
    }

    private var appliedTitle: String {
        switch item.action {
        case "archive": "Archived"
        case "follow_up": "Follow-up set"
        default: "Added to Needs Reply"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: isApplied ? .center : .top, spacing: 10) {
                ZStack {
                    Circle().fill(isApplied ? palette.selectionFill : palette.accentInk.opacity(0.10))
                    PostmereIcon(isApplied ? "checkmark" : symbol, size: 15)
                        .foregroundStyle(isApplied ? palette.selectionInk : palette.accentInk)
                        .id(isApplied)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isApplied ? appliedTitle : title)
                        .font(.system(size: 13, weight: .semibold))
                        .id(isApplied)
                        .transition(.opacity)
                    if !isApplied {
                        Text(verbatim: item.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                if isApplied {
                    Button("Undo", action: onUndo)
                        .buttonStyle(AccentLinkStyle())
                        .font(.caption)
                        .transition(.opacity.combined(with: .offset(x: 6)))
                } else {
                    Button(action: onDismiss) { PostmereIcon("xmark", size: 10) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                        .help("Dismiss suggestion")
                        .accessibilityLabel("Dismiss suggestion")
                }
            }
            if !isApplied {
                HStack(spacing: 8) {
                    if let source {
                        Button { onOpenSource(source) } label: {
                            Text(source.sender.isEmpty ? MailMessage.displaySubject(source.subject) : source.sender)
                                .lineLimit(1)
                        }
                        .buttonStyle(.accentLink)
                        .font(.caption)
                        .help("Show the message this is based on")
                        .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    Button("Apply", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isReady)
                        .animation(.smooth, value: isReady)
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(isApplied ? palette.selectionFill.opacity(0.35) : inset,
                    in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(hovering && !isApplied ? palette.accentInk.opacity(0.25) : .clear))
        .offset(y: hovering && !isApplied ? -1 : 0)
        .shadow(color: .black.opacity(hovering && !isApplied ? 0.06 : 0), radius: 8, y: 4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .contain)
    }
}
