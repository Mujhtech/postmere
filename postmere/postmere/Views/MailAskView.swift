import SwiftUI

/// Text that arrives in network bursts but is revealed at a steady pace,
/// catching up quickly when a backlog builds.
@MainActor @Observable
final class PacedText {
    private(set) var shown = ""
    private(set) var isRevealing = false
    private var pending = ""
    private var task: Task<Void, Never>?

    func append(_ text: String) {
        pending += text
        guard task == nil else { return }
        isRevealing = true
        task = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                let next = self.pending.prefix(max(2, self.pending.count / 10))
                self.shown += next
                self.pending.removeFirst(next.count)
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.task = nil
            self?.isRevealing = false
        }
    }

    /// Reconciles with the final text, continuing the reveal where it is.
    func finish(with text: String) {
        let received = shown + pending
        if text.hasPrefix(received) {
            append(String(text.dropFirst(received.count)))
        } else {
            reset()
            append(text)
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        shown = ""
        pending = ""
        isRevealing = false
    }
}

/// One question and its streamed answer.
@MainActor @Observable
final class MailAskTurn: Identifiable {
    enum Phase: Equatable {
        case searching, answering, done
        case failed(String, canRetry: Bool)
    }

    let id = UUID()
    let question: String
    let accountIDs: [UUID]
    let answer = PacedText()
    private(set) var phase: Phase = .searching
    private(set) var sources: [MailAISource] = []
    private(set) var result: MailAIResult?

    init(question: String, accountIDs: [UUID]) {
        self.question = question
        self.accountIDs = accountIDs
    }

    /// Cited sources first, then anything else the answer drew on.
    var orderedSources: [MailAISource] {
        let cited = Set(result?.items.flatMap(\.sourceIds) ?? [])
        return sources.filter { cited.contains($0.id) } + sources.filter { !cited.contains($0.id) }
    }

    func run(session: BackendSession) async {
        phase = .searching
        answer.reset()
        sources = []
        result = nil
        do {
            let result = try await session.ask(question: question, accountIDs: accountIDs, onSources: { found in
                withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
                    self.sources = found
                    self.phase = .answering
                }
            }, onDelta: { chunk in
                if self.phase == .searching { withAnimation(.smooth) { self.phase = .answering } }
                self.answer.append(chunk)
            })
            try Task.checkCancellation()
            answer.finish(with: result.text)
            withAnimation(.smooth(duration: 0.4)) {
                if sources.isEmpty { sources = result.sources }
                self.result = result
                phase = .done
            }
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) {
                phase = .failed(error.localizedDescription, canRetry: (error as? BackendAIError)?.canRetry ?? true)
            }
        }
    }
}

/// Ask questions about indexed mail as a short conversation with streamed,
/// sourced answers.
struct MailAskView: View {
    let runtime: MailRuntime

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Namespace private var fieldSpace
    @State private var settings: MailAISettings?
    @State private var settingsError: String?
    @State private var enabling = false
    @State private var turns: [MailAskTurn] = []
    @State private var draft = ""
    @State private var accountID: UUID?
    @State private var running: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private var isReady: Bool { settings.map { $0.enabled && $0.available } ?? false }
    private var isWorking: Bool {
        guard let last = turns.last else { return false }
        return last.phase == .searching || last.phase == .answering || last.answer.isRevealing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if turns.isEmpty {
                hero.transition(.opacity)
            } else {
                conversation.transition(.opacity)
                Divider().opacity(0.6)
                field
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 680, height: 640)
        .tint(palette.accentInk)
        .mailPanelSurface()
        .task { await loadSettings() }
        .onDisappear { running?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            PostmereIcon("sparkles", size: 14).foregroundStyle(palette.accentInk)
            Text("Ask your mail").font(.system(size: 13, weight: .semibold))
            Spacer()
            if !turns.isEmpty {
                Button("New Question", action: startOver)
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .disabled(isWorking)
            }
            Button { dismiss() } label: { PostmereIcon("xmark", size: 11) }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                AskOrb(isWorking: false)
                    .scaleEffect(1.3)
                    .padding(.bottom, 6)
                Text("What do you want to know?")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                Text("Answers come from mail synced to your workspace, with the messages they’re based on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let settings, !isReady {
                consent(settings)
            } else if let settingsError {
                Text(settingsError).font(.callout).foregroundStyle(PostmereTheme.destructiveInk)
            } else {
                field.padding(.horizontal, 40)
                starters
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func consent(_ settings: MailAISettings) -> some View {
        VStack(spacing: 12) {
            Text(settings.available ? settings.dataNotice : "Your workspace administrator needs to configure an AI provider.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if settings.available {
                Button { Task { await enable() } } label: {
                    Text(enabling ? "Enabling…" : "Enable AI for My Account")
                }
                .buttonStyle(.borderedProminent)
                .disabled(enabling)
            }
        }
    }

    private var starters: some View {
        let prompts = starterPrompts
        return VStack(spacing: 8) {
            Text("Try asking")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            FlowRow(spacing: 8) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                    Button { submit(prompt) } label: {
                        Text(prompt)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(StarterStyle())
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4).delay(0.05 * Double(index)), value: prompts.count)
                }
            }
            .frame(maxWidth: 520)
        }
    }

    /// Generic questions plus a couple about the people who wrote most recently.
    private var starterPrompts: [String] {
        var seen = Set<String>()
        let recent = runtime.store.messages
            .filter { !$0.isOutgoing && $0.mailbox == .inbox && !$0.sender.isEmpty && !$0.sender.contains("@") }
            .sorted { $0.sentAt > $1.sentAt }
            .compactMap { message -> String? in
                let name = message.sender.split(separator: " ").first.map(String.init) ?? message.sender
                return seen.insert(name.lowercased()).inserted ? name : nil
            }
            .prefix(2)
        return ["What needs my reply this week?"]
            + recent.map { "What’s the latest from \($0)?" }
            + ["Any invoices or receipts this month?", "What did I miss in the last few days?"]
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            PostmereIcon("sparkles", size: 15).foregroundStyle(palette.accentInk)
            TextField("Ask anything about your mail", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($fieldFocused)
                .onSubmit { submit(draft) }
                .disabled(!isReady)
            scopeMenu
            Button { submit(draft) } label: {
                PostmereIcon("arrow.up", size: 13)
                    .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(canSubmit ? palette.accent : PostmereTheme.rule, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
            .help("Ask (Return)")
            .accessibilityLabel("Ask")
            .animation(.snappy(duration: 0.2), value: canSubmit)
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(PostmereTheme.paper, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(fieldFocused ? palette.accentInk.opacity(0.45) : PostmereTheme.rule, lineWidth: fieldFocused ? 1.5 : 1))
        .shadow(color: .black.opacity(turns.isEmpty ? 0.07 : 0), radius: 14, y: 6)
        .matchedGeometryEffect(id: "field", in: fieldSpace)
        .animation(.easeOut(duration: 0.15), value: fieldFocused)
        .onAppear {
            fieldFocused = true
            if let pending = runtime.pendingAIQuestion {
                runtime.pendingAIQuestion = nil
                draft = pending
            }
        }
    }

    private var canSubmit: Bool {
        isReady && !isWorking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scopeMenu: some View {
        Menu {
            Button { accountID = nil } label: {
                if accountID == nil { Label("All accounts", systemImage: "checkmark") } else { Text("All accounts") }
            }
            if !runtime.backend.accounts.isEmpty { Divider() }
            ForEach(runtime.backend.accounts) { account in
                Button { accountID = account.id } label: {
                    if accountID == account.id { Label(account.email, systemImage: "checkmark") } else { Text(account.email) }
                }
            }
        } label: {
            Text(runtime.backend.accounts.first { $0.id == accountID }?.email ?? "All accounts")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(palette.accentInk.opacity(0.08), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which accounts to search")
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(turns) { turn in
                        AskTurnView(turn: turn,
                                    onRetry: { retry(turn) },
                                    onOpen: { source in Task { await open(source) } })
                            .id(turn.id)
                            .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .onChange(of: turns.last?.answer.shown.count) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: turns.count) {
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Actions

    private func submit(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !isWorking, !question.isEmpty else { return }
        let turn = MailAskTurn(question: question, accountIDs: accountID.map { [$0] } ?? [])
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.15)) {
            turns.append(turn)
            draft = ""
        }
        running = Task { await turn.run(session: runtime.backend) }
    }

    private func retry(_ turn: MailAskTurn) {
        running?.cancel()
        running = Task { await turn.run(session: runtime.backend) }
    }

    private func startOver() {
        running?.cancel()
        withAnimation(.spring(duration: 0.5, bounce: 0.1)) { turns = [] }
        fieldFocused = true
    }

    private func loadSettings() async {
        guard runtime.backend.canAccessWorkspace else {
            settingsError = "Connect your Postmere workspace in Settings → Accounts to ask about your mail."
            return
        }
        do {
            let loaded: MailAISettings = try await runtime.backend.request("GET", "/v1/ai/settings")
            withAnimation(.smooth) { settings = loaded }
        } catch { settingsError = error.localizedDescription }
        accountID = runtime.store.selectedAccount.flatMap(MailAccount.init(rawValue:))?.remote?.accountID
    }

    private func enable() async {
        enabling = true
        defer { enabling = false }
        do {
            let updated: MailAISettings = try await runtime.backend.request(
                "PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: true, styleGuide: settings?.styleGuide ?? ""))
            withAnimation(.smooth) { settings = updated }
            fieldFocused = true
        } catch { settingsError = error.localizedDescription }
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
            dismiss()
        } catch { settingsError = error.localizedDescription }
    }
}

// MARK: - Turn

private struct AskTurnView: View {
    let turn: MailAskTurn
    let onRetry: () -> Void
    let onOpen: (MailAISource) -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAllSources = false

    private var isWorking: Bool { turn.phase == .searching || turn.phase == .answering }

    private var status: String {
        switch turn.phase {
        case .searching: "Searching your mail…"
        case .answering:
            turn.sources.isEmpty ? "Writing an answer…" : "Reading \(turn.sources.count) message\(turn.sources.count == 1 ? "" : "s")…"
        case .done:
            turn.sources.isEmpty ? "No matching mail found" : "Based on \(turn.sources.count) message\(turn.sources.count == 1 ? "" : "s")"
        case .failed: "Couldn’t answer that"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer(minLength: 80)
                Text(verbatim: turn.question)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.selectionInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(palette.selectionFill, in: .rect(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AskOrb(isWorking: isWorking)
                    ZStack(alignment: .leading) {
                        Text(status)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .id(status)
                            .transition(reduceMotion ? .opacity : .push(from: .bottom))
                    }
                    .clipped()
                    .animation(.snappy(duration: 0.3), value: status)
                    if !turn.sources.isEmpty {
                        SourceStack(sources: Array(turn.sources.prefix(5)))
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                    }
                }
                if !turn.answer.shown.isEmpty {
                    answerText
                }
                if case .failed(let message, let canRetry) = turn.phase {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if canRetry { Button("Try Again", action: onRetry).buttonStyle(.accentLink) }
                    }
                }
                if turn.phase == .done && !turn.answer.isRevealing && !turn.orderedSources.isEmpty {
                    sourceList.transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .padding(.leading, 2)
        }
        .animation(.smooth(duration: 0.35), value: turn.answer.isRevealing)
    }

    private var answerText: some View {
        let typing = turn.phase != .done || turn.answer.isRevealing
        return TimelineView(.animation(paused: !typing)) { context in
            let wave = (cos(context.date.timeIntervalSinceReferenceDate * .pi * 1.6) + 1) / 2
            let caret = Text(verbatim: typing ? " ▍" : "")
                .foregroundStyle(palette.accentInk.opacity(reduceMotion ? 0.8 : 0.25 + 0.75 * wave))
            Text("\(Text(verbatim: turn.answer.shown))\(caret)")
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 42)
    }

    private var sourceList: some View {
        let sources = turn.orderedSources
        let cited = Set(turn.result?.items.flatMap(\.sourceIds) ?? [])
        let visible = showsAllSources ? sources : Array(sources.prefix(4))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            VStack(spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, source in
                    SourceRow(source: source, isCited: cited.contains(source.id)) { onOpen(source) }
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.35).delay(0.04 * Double(index)), value: visible.count)
                }
            }
            if sources.count > 4 {
                Button(showsAllSources ? "Show fewer" : "Show all \(sources.count)") {
                    withAnimation(.smooth(duration: 0.3)) { showsAllSources.toggle() }
                }
                .buttonStyle(.accentLink)
                .font(.caption)
            }
        }
        .padding(.leading, 42)
    }
}

private struct SourceRow: View {
    let source: MailAISource
    let isCited: Bool
    let onOpen: () -> Void

    @Environment(\.postmereAccent) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                MailParticipantAvatar(address: source.senderAddress, name: source.senderName, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.senderName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(MailMessage.displaySubject(source.subject))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if isCited {
                    Text("Cited")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.accentInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.accentInk.opacity(0.10), in: Capsule())
                }
                Text(source.sentAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PostmereIcon("chevron.right", size: 9)
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering ? palette.selectionFill.opacity(0.6) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Open this message")
    }
}

/// Overlapping avatars for the first few retrieved messages.
private struct SourceStack: View {
    let sources: [MailAISource]

    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                MailParticipantAvatar(address: source.senderAddress, name: source.senderName, size: 22)
                    .overlay(Circle().strokeBorder(PostmereTheme.paper, lineWidth: 1.5))
                    .zIndex(Double(sources.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AskOrb: View {
    let isWorking: Bool

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(palette.selectionFill)
            if isWorking && !reduceMotion {
                Circle()
                    .strokeBorder(palette.accentInk.opacity(0.5), lineWidth: 1.5)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring.scaleEffect(expanded ? 1.45 : 1).opacity(expanded ? 0 : 1)
                    } animation: { expanded in expanded ? .easeOut(duration: 1.3) : .linear(duration: 0) }
                    .transition(.opacity)
            }
            PostmereIcon("sparkles", size: 14).foregroundStyle(palette.accentInk)
        }
        .frame(width: 30, height: 30)
        .animation(.smooth, value: isWorking)
        .accessibilityHidden(true)
    }
}

private struct StarterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StarterBody(configuration: configuration)
    }

    private struct StarterBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.postmereAccent) private var palette
        @Environment(\.mailboxInset) private var inset
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? palette.selectionInk : .primary)
                .background(hovering ? palette.selectionFill : inset, in: Capsule())
                .overlay(Capsule().strokeBorder(PostmereTheme.rule.opacity(hovering ? 0 : 1)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.snappy(duration: 0.2), value: configuration.isPressed)
        }
    }
}

/// Lays out children left to right, wrapping onto centered rows.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

private extension MailAISource {
    var senderAddress: String { MailSenderDomain.email(in: sender) ?? "" }
    var senderName: String {
        let name = sender.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\""))) } ?? ""
        return name.isEmpty ? (senderAddress.isEmpty ? "Unknown sender" : senderAddress) : name
    }
}
