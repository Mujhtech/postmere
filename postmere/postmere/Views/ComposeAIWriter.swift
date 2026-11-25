import SwiftUI

/// Writing help that lives inside the composer: describe what to say or pick a
/// quick edit, watch the text stream in, then replace or insert it.
struct ComposeAIWriter: View {
    let runtime: MailRuntime
    let store: MailStore
    let formatting: ComposeTextFormatting
    let onClose: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var promptFocused: Bool
    @State private var prompt = ""
    @State private var phase: Phase = .loading
    @State private var settings: MailAISettings?
    @State private var output = PacedText()
    @State private var lastRequest: (instruction: Instruction, notes: String)?
    @State private var running: Task<Void, Never>?

    private enum Phase: Equatable {
        case loading, consent, unavailable, idle, writing, ready
        case failed(String, canRetry: Bool)

        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    private enum Instruction: String, CaseIterable {
        case reply, shorten, clarify, friendly, formal, expand

        var title: String {
            switch self {
            case .reply: "Draft a reply"
            case .shorten: "Shorten"
            case .clarify: "Clarify"
            case .friendly: "Friendlier"
            case .formal: "More formal"
            case .expand: "Expand"
            }
        }

        var symbol: String {
            switch self {
            case .reply: "arrowshape.turn.up.left"
            case .shorten: "text.alignleft"
            case .clarify: "sparkles"
            case .friendly: "face.smiling"
            case .formal: "doc.text"
            case .expand: "text.badge.plus"
            }
        }
    }

    private var draft: String { store.draftBody.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Messages from the conversation being answered, as the server knows them.
    private var sourceIDs: [UUID] {
        MailAIAssist.writerSourceIDs(store: store, scope: runtime.backend.scope)
    }

    private var quickActions: [Instruction] {
        if draft.isEmpty { return sourceIDs.isEmpty ? [] : [.reply] }
        return [.shorten, .clarify, .friendly, .formal, .expand]
    }

    private var placeholder: String {
        if !draft.isEmpty { return "Tell Postmere how to change your draft…" }
        return sourceIDs.isEmpty ? "Describe the email you want to write…" : "What do you want to say in your reply?"
    }

    private var isWriting: Bool { phase == .writing || output.isRevealing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting ready…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    closeButton
                }
            case .consent:
                consent
            case .unavailable:
                HStack {
                    Text("AI writing needs your workspace connected and an AI provider configured by your administrator.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    closeButton
                }
            default:
                if phase == .writing || phase == .ready || !output.shown.isEmpty {
                    result.transition(.opacity.combined(with: .offset(y: 8)))
                }
                if case .failed(let message, let canRetry) = phase {
                    HStack(spacing: 8) {
                        Text(message).font(.callout).foregroundStyle(PostmereTheme.destructiveInk)
                        if canRetry, lastRequest != nil { Button("Try Again", action: retry).buttonStyle(.accentLink) }
                    }
                }
                promptRow
                if phase == .idle || phase.isFailure, !quickActions.isEmpty {
                    chips.transition(.opacity)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.accentInk.opacity(0.22)))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
        .frame(maxWidth: 640)
        .tint(palette.accentInk)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.12), value: phase)
        .animation(.smooth(duration: 0.3), value: output.isRevealing)
        .onExitCommand(perform: dismiss)
        .task { await loadSettings() }
        .onDisappear { running?.cancel() }
    }

    // MARK: Prompt

    private var promptRow: some View {
        HStack(spacing: 10) {
            PostmereIcon("sparkles", size: 15)
                .foregroundStyle(palette.accentInk)
                .symbolEffect(.pulse, isActive: isWriting && !reduceMotion)
            TextField(placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .focused($promptFocused)
                .onSubmit(submitPrompt)
                .disabled(isWriting)
            if isWriting {
                Button("Stop", action: stop)
                    .buttonStyle(.accentLink)
                    .font(.callout)
                    .transition(.opacity)
            } else {
                Button(action: submitPrompt) {
                    PostmereIcon("arrow.up", size: 12)
                        .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(canSubmit ? palette.accent : PostmereTheme.rule, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help("Write (Return)")
                .accessibilityLabel("Write")
                .transition(.opacity)
            }
            closeButton
        }
        .onAppear { promptFocused = true }
    }

    private var closeButton: some View {
        Button(action: dismiss) { PostmereIcon("xmark", size: 10) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close (Esc)")
            .accessibilityLabel("Close AI writing")
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.isEmpty || !sourceIDs.isEmpty
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(quickActions, id: \.self) { action in
                Button { write(action, notes: prompt) } label: {
                    HStack(spacing: 5) {
                        PostmereIcon(action.symbol, size: 11)
                        Text(action.title)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(WriterChipStyle())
            }
        }
        .padding(.leading, 25)
    }

    // MARK: Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(isWriting ? "Writing…" : "Suggested text")
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(palette.accentInk)
                    .contentTransition(.opacity)
                Spacer()
            }
            ScrollView {
                TimelineView(.animation(paused: !isWriting)) { context in
                    let wave = (cos(context.date.timeIntervalSinceReferenceDate * .pi * 1.6) + 1) / 2
                    let caret = Text(verbatim: isWriting ? " ▍" : "")
                        .foregroundStyle(palette.accentInk.opacity(reduceMotion ? 0.8 : 0.25 + 0.75 * wave))
                    Text("\(Text(verbatim: output.shown))\(caret)")
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxHeight: 240)
            .scrollBounceBehavior(.basedOnSize)
            if phase == .ready && !output.isRevealing {
                HStack(spacing: 8) {
                    Button { apply(replacing: true) } label: { Text(draft.isEmpty ? "Use This Text" : "Replace Draft") }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                        .help("Return")
                    if !draft.isEmpty {
                        Button("Insert at Cursor") { apply(replacing: false) }
                    }
                    Button("Try Again", action: retry)
                    Spacer()
                    Button("Discard", action: discard)
                        .buttonStyle(.accentLink)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.regular)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .padding(12)
        .background(PostmereTheme.paper.opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
    }

    // MARK: Consent

    private var consent: some View {
        HStack(alignment: .top, spacing: 10) {
            PostmereIcon("sparkles", size: 15).foregroundStyle(palette.accentInk)
            VStack(alignment: .leading, spacing: 8) {
                Text(settings?.dataNotice ?? "").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Enable AI Writing") { Task { await enable() } }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
            }
            Spacer()
            closeButton
        }
    }

    // MARK: Actions

    private func submitPrompt() {
        if phase == .ready, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apply(replacing: true)
            return
        }
        guard canSubmit, !isWriting else { return }
        let instruction: Instruction = draft.isEmpty ? (sourceIDs.isEmpty ? .expand : .reply) : .clarify
        write(instruction, notes: prompt)
    }

    private func write(_ instruction: Instruction, notes: String) {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        lastRequest = (instruction, notes)
        running?.cancel()
        output.reset()
        phase = .writing
        let input = MailAIDraftInput(messageIds: sourceIDs, draftText: MailQuotedReply.split(store.draftBody)?.head ?? store.draftBody,
                                     instruction: instruction.rawValue, notes: notes)
        running = Task {
            do {
                let result = try await runtime.backend.draft(input) { chunk in output.append(chunk) }
                try Task.checkCancellation()
                output.finish(with: result.text)
                phase = .ready
                prompt = ""
                promptFocused = true
            } catch {
                guard !Task.isCancelled else { return }
                output.reset()
                phase = .failed(error.localizedDescription, canRetry: (error as? BackendAIError)?.canRetry ?? true)
            }
        }
    }

    private func retry() {
        guard let lastRequest else { return }
        write(lastRequest.instruction, notes: lastRequest.notes)
    }

    private func stop() {
        running?.cancel()
        phase = output.shown.isEmpty ? .idle : .ready
    }

    private func apply(replacing: Bool) {
        let text = output.shown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if replacing || draft.isEmpty { formatting.replaceBodyWithSuggestion(text) } else { formatting.insertText(text) }
        onClose()
    }

    private func discard() {
        running?.cancel()
        output.reset()
        phase = .idle
        promptFocused = true
    }

    /// Escape steps back: discard a result first, then close.
    private func dismiss() {
        if phase == .ready || phase == .writing { discard() } else { onClose() }
    }

    private func loadSettings() async {
        guard runtime.backend.canAccessWorkspace else { phase = .unavailable; return }
        do {
            let loaded: MailAISettings = try await runtime.backend.request("GET", "/v1/ai/settings")
            settings = loaded
            phase = !loaded.available ? .unavailable : loaded.enabled ? .idle : .consent
            // A draft asked for elsewhere (Draft intro) starts once AI writing is on.
            if let pending = store.pendingWriterPrompt {
                store.pendingWriterPrompt = nil
                if phase == .idle || phase == .consent { prompt = pending }
                if phase == .idle { submitPrompt() }
            }
        } catch {
            store.pendingWriterPrompt = nil
            phase = .failed(error.localizedDescription, canRetry: false)
        }
    }

    private func enable() async {
        do {
            let updated: MailAISettings = try await runtime.backend.request(
                "PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: true, styleGuide: settings?.styleGuide ?? ""))
            settings = updated
            phase = updated.enabled ? .idle : .consent
        } catch {
            phase = .failed(error.localizedDescription, canRetry: false)
        }
    }
}

/// A small invitation shown in an empty body so AI writing is discoverable.
struct ComposeAIHint: View {
    let action: () -> Void
    @Environment(\.postmereAccent) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                PostmereIcon("sparkles", size: 13)
                Text("Write with AI")
                Text("⌘J")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(palette.accentInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(hovering ? palette.selectionFill : palette.accentInk.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(palette.accentInk.opacity(hovering ? 0.3 : 0.15)))
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .help("Write or edit this message with AI (⌘J)")
    }
}

private struct WriterChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration)
    }

    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.postmereAccent) private var palette
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? palette.selectionInk : .primary)
                .background(hovering ? palette.selectionFill : PostmereTheme.paper.opacity(0.8), in: Capsule())
                .overlay(Capsule().strokeBorder(PostmereTheme.rule.opacity(hovering ? 0 : 1)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.snappy(duration: 0.2), value: configuration.isPressed)
        }
    }
}
