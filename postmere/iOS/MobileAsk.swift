import SwiftUI
import UIKit

/// Ask questions about your mail as a short chat, with streamed answers that
/// show what they're reading and cite the messages they came from.
struct MobileAskScreen: View {
    let runtime: MailRuntime
    /// A tab rather than a presented screen: no Close button.
    var embedded = false
    /// Opens a source message in the mailbox.
    let onOpen: (MailMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var settings: MailAISettings?
    @State private var settingsError: String?
    @State private var turns: [MailAskTurn] = []
    @State private var draft = ""
    @State private var accountID: UUID?
    @State private var running: Task<Void, Never>?
    @State private var openError: String?
    @FocusState private var focused: Bool

    private var isReady: Bool { settings.map { $0.enabled && $0.available } ?? false }
    private var isWorking: Bool {
        guard let last = turns.last else { return false }
        return last.phase == .searching || last.phase == .answering || last.answer.isRevealing
    }

    var body: some View {
        NavigationStack {
            Group {
                if turns.isEmpty { welcome } else { conversation }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { MobileAskBackdrop(active: isWorking) }
            .safeAreaInset(edge: .bottom) {
                if isReady {
                    VStack(spacing: 10) {
                        if turns.isEmpty { starters }
                        field
                    }
                    .padding(.bottom, 6)
                }
            }
            .aboveMobileTabBar()
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { running?.cancel(); dismiss() }
                    }
                }
                ToolbarItem(placement: .principal) { scopeMenu }
                if !turns.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Chat", systemImage: "square.and.pencil") {
                            running?.cancel()
                            withAnimation(.snappy) { turns = [] }
                            focused = true
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadSettings() }
        }
        .tint(palette.accent)
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            MobileAskOrb(working: false, size: 64)
            Text("What do you want to know?")
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
            Group {
                if let settingsError {
                    Text(settingsError)
                } else if let settings, !settings.available {
                    Text("Your workspace administrator needs to set up an AI provider first.")
                } else if let settings, !settings.enabled {
                    Text(settings.dataNotice)
                } else {
                    Text("Ask anything about your mail. Answers show the messages they come from.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
            if let settings, settings.available, !settings.enabled {
                Button("Turn On AI") { Task { await enable() } }
                    .buttonStyle(.glassProminent)
                    .padding(.top, 6)
            } else if settings == nil && settingsError == nil {
                ProgressView().padding(.top, 6)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
    }

    /// Two-line prompt cards above the field, scrolled sideways.
    private var starters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(starterPrompts, id: \.title) { prompt in
                    Button { submit(prompt.question) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                            Text(prompt.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(minWidth: 150, alignment: .leading)
                        .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .scrollClipDisabled()
    }

    private struct Starter {
        let title: String
        let detail: String
        let question: String
    }

    private var starterPrompts: [Starter] {
        var result = [Starter(title: "Needs my reply", detail: "this week", question: "What needs my reply this week?")]
        if let name = recentSender {
            result.append(Starter(title: "Latest from", detail: name, question: "What’s the latest from \(name)?"))
        }
        result.append(Starter(title: "Invoices & receipts", detail: "this month", question: "Any invoices or receipts this month?"))
        result.append(Starter(title: "What did I miss", detail: "in the last few days", question: "What did I miss in the last few days?"))
        return result
    }

    /// The most recent person who wrote to you, by their full display name.
    private var recentSender: String? {
        runtime.store.messages
            .filter { $0.mailbox == .inbox && !$0.isOutgoing && !$0.sender.isEmpty && !$0.sender.contains("@") }
            .max { $0.sentAt < $1.sentAt }?
            .sender
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(turns) { turn in
                        MobileAskTurnView(turn: turn, onRetry: { retry(turn) }, onOpen: open,
                                          onFollowUp: { draft = ""; focused = true })
                            .id(turn.id)
                    }
                    if let openError {
                        Text(openError).font(.footnote).foregroundStyle(PostmereTheme.destructiveInk)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, Mobile.gutter)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) { withAnimation(.snappy) { proxy.scrollTo(turns.last?.id, anchor: .top) } }
        }
    }

    // MARK: Input

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(turns.isEmpty ? "Ask about your mail" : "Ask a follow-up", text: $draft, axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(1...5)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { submit(draft) }
                .padding(.leading, 15)
                .padding(.vertical, 11)
            Button {
                if isWorking { stop() } else { submit(draft) }
            } label: {
                Image(systemName: isWorking ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend || isWorking ? palette.accent : Color(uiColor: .systemGray3), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !isWorking)
            .accessibilityLabel(isWorking ? "Stop" : "Ask")
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
        .animation(.snappy(duration: 0.2), value: canSend)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Which accounts answers come from.
    private var scopeMenu: some View {
        Menu {
            Button { accountID = nil } label: {
                if accountID == nil { Label("All accounts", systemImage: "checkmark") } else { Text("All accounts") }
            }
            ForEach(runtime.backend.accounts) { account in
                Button { accountID = account.id } label: {
                    if accountID == account.id { Label(account.email, systemImage: "checkmark") } else { Text(account.email) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(runtime.backend.accounts.first { $0.id == accountID }?.email ?? "All accounts")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
        }
        .disabled(runtime.backend.accounts.count < 2 || isWorking)
    }

    // MARK: Actions

    private func submit(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !isWorking, !question.isEmpty else { return }
        let turn = MailAskTurn(question: question, accountIDs: accountID.map { [$0] } ?? [])
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
            turns.append(turn)
            draft = ""
        }
        focused = false
        running = Task {
            await turn.run(session: runtime.backend)
            if turn.phase == .done { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }

    private func stop() {
        running?.cancel()
        running = nil
        turns.last?.stop()
    }

    private func retry(_ turn: MailAskTurn) {
        running?.cancel()
        running = Task { await turn.run(session: runtime.backend) }
    }

    private func loadSettings() async {
        guard runtime.backend.canAccessWorkspace else {
            settingsError = "Connect your workspace to ask about your mail."
            return
        }
        accountID = runtime.store.selectedAccount.flatMap(MailAccount.init(rawValue:))?.remote?.accountID
        do {
            let loaded: MailAISettings = try await runtime.backend.request("GET", "/v1/ai/settings")
            withAnimation(.smooth) { settings = loaded }
        } catch { settingsError = error.localizedDescription }
        #if DEBUG
        // `simctl launch … -PostmereOpenAsk -PostmereAskQuestion "…"` asks straight away.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-PostmereAskQuestion"), arguments.indices.contains(index + 1) {
            submit(arguments[index + 1])
        }
        #endif
    }

    private func enable() async {
        do {
            let updated: MailAISettings = try await runtime.backend.request(
                "PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: true, styleGuide: settings?.styleGuide ?? ""))
            withAnimation(.smooth) { settings = updated }
            if updated.enabled { focused = true }
        } catch { settingsError = error.localizedDescription }
    }

    private func open(_ source: MailAISource) {
        Task {
            do {
                guard let identity = RemoteAccountRegistry.accounts.first(where: {
                    $0.accountID == source.accountId && $0.scope == runtime.backend.scope
                }) else { throw BackendError.notConnected }
                let message = try await runtime.fetchProviderMessage(source.id, for: identity)
                if !embedded { dismiss() }
                onOpen(message)
            } catch { openError = error.localizedDescription }
        }
    }
}

// MARK: - Turn

private struct MobileAskTurnView: View {
    let turn: MailAskTurn
    let onRetry: () -> Void
    let onOpen: (MailAISource) -> Void
    let onFollowUp: () -> Void
    @Environment(\.postmereAccent) private var palette
    @State private var showsAllSources = false
    @State private var copied = false

    private var isWorking: Bool { turn.phase == .searching || turn.phase == .answering }

    private var status: String {
        let count = turn.sources.count
        let messages = "\(count) message\(count == 1 ? "" : "s")"
        switch turn.phase {
        case .searching: return "Searching your mail…"
        case .answering: return count == 0 ? "Writing an answer…" : "Reading \(messages)…"
        case .done: return count == 0 ? "No matching mail found" : "Based on \(messages)"
        case .failed: return "Couldn’t answer that"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer(minLength: 60)
                Text(verbatim: turn.question)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                MobileAskOrb(working: isWorking || turn.answer.isRevealing, size: 26)
                Text(status)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.snappy, value: status)
                if !turn.sources.isEmpty {
                    sourceStack.transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            if !turn.answer.shown.isEmpty { answer }
            if case .failed(let message, let canRetry) = turn.phase {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                    if canRetry { Button("Try Again", action: onRetry).buttonStyle(.glass) }
                }
            }
            if turn.phase == .done && !turn.answer.isRevealing {
                actions
                if !turn.orderedSources.isEmpty { sources }
            }
        }
        .animation(.smooth(duration: 0.35), value: turn.phase)
        .animation(.smooth(duration: 0.35), value: turn.answer.isRevealing)
    }

    /// Markdown answer with a caret while it is still arriving.
    private var answer: some View {
        let typing = turn.phase != .done || turn.answer.isRevealing
        let body = (try? AttributedString(markdown: turn.answer.shown,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(turn.answer.shown)
        return Text("\(body)\(Text(verbatim: typing ? " ▍" : "").foregroundStyle(palette.accent))")
            .font(.system(size: 17))
            .lineSpacing(5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button {
                UIPasteboard.general.string = turn.answer.shown
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 34, height: 30)
            }
            .accessibilityLabel(copied ? "Copied" : "Copy answer")
            ShareLink(item: turn.answer.shown) {
                Image(systemName: "square.and.arrow.up").frame(width: 34, height: 30)
            }
            .accessibilityLabel("Share answer")
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise").frame(width: 34, height: 30)
            }
            .accessibilityLabel("Ask again")
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Overlapping photos of the first few messages being read.
    private var sourceStack: some View {
        HStack(spacing: -8) {
            ForEach(Array(turn.sources.prefix(4))) { source in
                ParticipantPhoto(address: source.senderAddress, name: source.senderName, size: 22)
                    .overlay { Circle().strokeBorder(Mobile.background, lineWidth: 2) }
            }
        }
        .accessibilityHidden(true)
    }

    private var sources: some View {
        let all = turn.orderedSources
        let cited = Set(turn.result?.items.flatMap(\.sourceIds) ?? [])
        let visible = showsAllSources ? all : Array(all.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            Text("SOURCES")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { MobileHairline(leading: 52) }
                    Button { onOpen(source) } label: {
                        HStack(spacing: 12) {
                            ParticipantPhoto(address: source.senderAddress, name: source.senderName, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(source.senderName).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                                    if cited.contains(source.id) {
                                        Text("Cited")
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundStyle(palette.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(palette.accent.opacity(0.12), in: Capsule())
                                    }
                                }
                                Text(MailMessage.displaySubject(source.subject))
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(source.sentAt.mobileListDate).font(.system(size: 12)).foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if all.count > 3 {
                Button(showsAllSources ? "Show fewer" : "Show all \(all.count) sources") {
                    withAnimation(.snappy) { showsAllSources.toggle() }
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}

// MARK: - Visuals

/// The assistant's mark: an accent orb that breathes while it works.
struct MobileAskOrb: View {
    let working: Bool
    let size: CGFloat
    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !working || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = working && !reduceMotion ? (sin(t * 3) + 1) / 2 : 0
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [palette.accent, palette.accent.opacity(0.55), palette.accent],
                                          center: .center, angle: .degrees(working ? t * 120 : 0)))
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: palette.accent.opacity(0.25 + 0.3 * pulse), radius: size * 0.25 * (1 + pulse))
            .scaleEffect(1 + 0.04 * pulse)
        }
        .accessibilityHidden(true)
    }
}

/// A soft accent glow behind the chat that brightens while an answer is coming in.
private struct MobileAskBackdrop: View {
    let active: Bool
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        Mobile.background
            .overlay(alignment: .bottom) {
                RadialGradient(colors: [palette.accent.opacity(active ? 0.16 : 0.09), .clear],
                               center: .bottom, startRadius: 0, endRadius: 420)
                    .frame(height: 520)
                    .animation(.smooth(duration: 0.8), value: active)
            }
            .ignoresSafeArea()
    }
}
