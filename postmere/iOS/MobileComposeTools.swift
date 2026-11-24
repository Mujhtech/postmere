import SwiftUI

// MARK: - Snippets and templates

/// Saved snippets add text to the body. Templates can also fill recipients, subject
/// and attachments. Either asks for any {placeholder} values first.
struct MobileSnippetSheet: View {
    @Bindable var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var search = ""
    @State private var filling: MailSnippet?
    @State private var values: [String: String] = [:]
    @State private var error: String?
    @State private var creates = false
    @State private var showsTeam = false
    @State private var team: [SharedSnippetSummary]?
    @State private var loadingTeam: UUID?
    @Environment(MailRuntime.self) private var runtime

    private var matches: [MailSnippet] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let filling {
                    placeholderForm(filling)
                } else {
                    list
                }
            }
            .navigationTitle(filling?.title ?? "Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if filling != nil {
                        Button("Back", systemImage: "chevron.left") { filling = nil; error = nil }
                    } else {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
                if filling == nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Snippet", systemImage: "plus") { creates = true }
                    }
                }
            }
            .sheet(isPresented: $creates) { MobileSnippetEditor(store: store, body: store.draftBody) }
        }
        .mobileSheetDetents()
    }

    private var list: some View {
        List {
            if runtime.backend.canAccessWorkspace {
                Picker("Source", selection: $showsTeam) {
                    Text("Mine").tag(false)
                    Text("Team").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let error {
                Text(error).foregroundStyle(PostmereTheme.destructiveInk)
            }
            if showsTeam { teamRows } else { mineRows }
        }
        .searchable(text: $search, prompt: "Search snippets")
        .task(id: showsTeam) { if showsTeam && team == nil { await loadTeam() } }
    }

    /// Templates published to the workspace. Choosing one saves a copy here, then uses it.
    @ViewBuilder private var teamRows: some View {
        if let team {
            let query = search.trimmingCharacters(in: .whitespaces)
            ForEach(team.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { summary in
                Button { Task { await useTeam(summary) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.fill").foregroundStyle(palette.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text("From \(summary.ownerEmail)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if loadingTeam == summary.id { ProgressView() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loadingTeam != nil)
            }
            if team.isEmpty {
                ContentUnavailableView("No team templates", systemImage: "person.2",
                    description: Text("Templates your workspace publishes from the Mac appear here."))
                    .listRowBackground(Color.clear)
            }
        } else {
            HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
        }
    }

    private func loadTeam() async {
        do {
            let list: SharedSnippetList = try await runtime.backend.request("GET", "/v1/shared/snippets")
            team = list.snippets
        } catch { self.error = error.localizedDescription; team = [] }
    }

    private func useTeam(_ summary: SharedSnippetSummary) async {
        loadingTeam = summary.id
        defer { loadingTeam = nil }
        do {
            let detail: SharedSnippetDetail = try await runtime.backend.request("GET", "/v1/shared/snippets/\(summary.id.uuidString)")
            let local = try WorkspaceTemplates.importTemplate(detail.template, store: store)
            store.saveSnippet(local)
            choose(local)
        } catch { self.error = error.localizedDescription }
    }

    @ViewBuilder private var mineRows: some View {
            ForEach(matches) { snippet in
                Button { choose(snippet) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: snippet.isTemplate ? "doc.text.fill" : "text.quote")
                            .foregroundStyle(palette.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snippet.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text(snippet.body.replacingOccurrences(of: "\n", with: " "))
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSnippet(snippet.id) }
                }
            }
            if store.snippets.isEmpty {
                ContentUnavailableView("No snippets yet", systemImage: "text.badge.plus",
                    description: Text("Save text you send often, like directions or a standard reply."))
                    .listRowBackground(Color.clear)
            }
    }

    private func placeholderForm(_ snippet: MailSnippet) -> some View {
        Form {
            Section {
                ForEach(MailTemplate.placeholderNames(in: snippet), id: \.self) { name in
                    TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                }
            } footer: {
                Text("These fill the {placeholders} in “\(snippet.title)”.")
            }
            if let error {
                Text(error).foregroundStyle(PostmereTheme.destructiveInk)
            }
            Section {
                Button("Insert") { apply(snippet) }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
        }
    }

    private func choose(_ snippet: MailSnippet) {
        error = nil
        if MailTemplate.placeholderNames(in: snippet).isEmpty {
            apply(snippet)
        } else {
            values = [:]
            filling = snippet
        }
    }

    private func apply(_ snippet: MailSnippet) {
        do {
            let draft = store.draftForTemplates
            let application = try MailTemplate.prepare(snippet, values: values, draft: draft, mode: .append)
            if application.changesHeaders { store.applyTemplateHeaders(application.afterHeaders) }
            store.draftBody = MailTemplate.resultingBody(application, draft: draft).string
            store.draftBodyRTF = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Save a new snippet, starting from the current draft body.
private struct MobileSnippetEditor: View {
    let store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text: String

    init(store: MailStore, body: String) {
        self.store = store
        _text = State(initialValue: body)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $title)
                Section {
                    TextEditor(text: $text).frame(minHeight: 180)
                } footer: {
                    Text("Use {name} for a value you fill in each time.")
                }
            }
            .navigationTitle("New Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        store.saveSnippet(MailSnippet(title: title.trimmingCharacters(in: .whitespaces), body: text))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty)
                }
            }
        }
    }
}

// MARK: - Write with AI

/// Draft a reply or rework the current draft, streamed from the workspace.
struct MobileAIWriterSheet: View {
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var prompt = ""
    @State private var phase: Phase = .loading
    @State private var settings: MailAISettings?
    @State private var output = ""
    @State private var running: Task<Void, Never>?
    @FocusState private var promptFocused: Bool

    private var store: MailStore { runtime.store }

    private enum Phase: Equatable {
        case loading, consent, unavailable, idle, writing, ready
        case failed(String)
    }

    private enum Instruction: String {
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

    private var sourceIDs: [UUID] {
        let scope = runtime.backend.scope
        let ids = store.messages
            .filter { $0.conversationID == store.draftConversationID && $0.account == store.draftAccount.rawValue
                && $0.mailAccount.remote?.scope == scope }
            .compactMap(\.backendMessageID)
        return Array(Set(ids).prefix(30))
    }

    private var quickActions: [Instruction] {
        if draft.isEmpty { return sourceIDs.isEmpty ? [] : [.reply] }
        return [.shorten, .clarify, .friendly, .formal, .expand]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                    case .consent:
                        Text(settings?.dataNotice ?? "").font(.subheadline).foregroundStyle(.secondary)
                        Button("Turn On AI Writing") { Task { await enable() } }
                            .buttonStyle(.glassProminent)
                            .tint(palette.accent)
                    case .unavailable:
                        Text("AI writing needs your workspace connected and an AI provider set up by your administrator.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    default:
                        if !quickActions.isEmpty && (phase == .idle || isFailure) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(quickActions, id: \.self) { action in
                                        Button { write(action, notes: "") } label: {
                                            Label(action.title, systemImage: action.symbol)
                                                .font(.subheadline.weight(.semibold))
                                                .padding(.horizontal, 12)
                                                .frame(height: 34)
                                                .background(Mobile.raised, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        if case .failed(let message) = phase {
                            Text(message).font(.subheadline).foregroundStyle(PostmereTheme.destructiveInk)
                        }
                        if phase == .writing || phase == .ready {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(verbatim: output.isEmpty ? "Writing…" : output)
                                    .font(.system(size: 16))
                                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if phase == .ready {
                                    HStack(spacing: 8) {
                                        Button(draft.isEmpty ? "Use" : "Replace Draft") { use(replacing: true) }
                                            .buttonStyle(.glassProminent)
                                            .tint(palette.accent)
                                        if !draft.isEmpty {
                                            Button("Add Below") { use(replacing: false) }.buttonStyle(.glass)
                                        }
                                        Button("Discard") { output = ""; phase = .idle }.buttonStyle(.glass)
                                    }
                                    .font(.subheadline.weight(.semibold))
                                }
                            }
                            .padding(14)
                            .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
                .padding(Mobile.gutter)
            }
            .safeAreaInset(edge: .bottom) {
                if phase == .idle || phase == .ready || isFailure { promptBar }
            }
            .navigationTitle("Write with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { running?.cancel(); dismiss() }
                }
                if phase == .writing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Stop", systemImage: "stop.fill") {
                            running?.cancel()
                            phase = output.isEmpty ? .idle : .ready
                        }
                    }
                }
            }
            .task { await loadSettings() }
        }
        .mobileSheetDetents()
    }

    private var isFailure: Bool { if case .failed = phase { true } else { false } }

    private var promptBar: some View {
        HStack(spacing: 8) {
            TextField(draft.isEmpty ? (sourceIDs.isEmpty ? "Describe the email…" : "What do you want to say?")
                      : "How should I change it?", text: $prompt, axis: .vertical)
                .lineLimit(1...4)
                .focused($promptFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            let empty = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                let instruction: Instruction = draft.isEmpty ? (sourceIDs.isEmpty ? .expand : .reply) : .clarify
                write(instruction, notes: prompt)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(empty ? Color(uiColor: .systemGray3) : palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .accessibilityLabel("Write")
            .padding(.trailing, 7)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func write(_ instruction: Instruction, notes: String) {
        running?.cancel()
        output = ""
        phase = .writing
        promptFocused = false
        let input = MailAIDraftInput(messageIds: sourceIDs, draftText: store.draftBody, instruction: instruction.rawValue,
                                     notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        running = Task {
            do {
                let result = try await runtime.backend.draft(input) { chunk in output.append(chunk) }
                try Task.checkCancellation()
                output = result.text
                phase = .ready
                prompt = ""
            } catch {
                guard !Task.isCancelled else { return }
                output = ""
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func use(replacing: Bool) {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.draftBody = replacing || draft.isEmpty ? text : store.draftBody + "\n\n" + text
        store.draftBodyRTF = nil
        dismiss()
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
                if phase == .idle { write(.expand, notes: pending); return }
            }
            if phase == .idle { promptFocused = true }
        } catch {
            store.pendingWriterPrompt = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func enable() async {
        do {
            let updated: MailAISettings = try await runtime.backend.request(
                "PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: true, styleGuide: settings?.styleGuide ?? ""))
            settings = updated
            phase = updated.enabled ? .idle : .consent
            if phase == .idle, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { write(.expand, notes: prompt) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Formatting

/// The phone composer writes light Markdown: **bold**, *italic*, `- ` lists and links.
/// Sending turns it into the rich version recipients see, and a clean plain-text version.
enum MobileMarkdown {
    private static let marker = /\*\*[^*\n]+\*\*|(?:^|[^*\w])\*[^*\s][^*\n]*\*(?![*\w])|\[[^\]\n]+\]\(https?:\/\/[^)\s]+\)|(?m:^[-*] )/

    /// nil when the text has no formatting, so ordinary mail is sent exactly as typed.
    static func rich(_ text: String) -> (plain: String, rtf: Data?)? {
        guard text.contains(marker) else { return nil }
        let bulleted = text.components(separatedBy: "\n").map { line in
            line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line
        }.joined(separator: "\n")
        guard let parsed = try? AttributedString(markdown: bulleted,
                                                 options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return nil
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = NSMutableAttributedString(attributedString: MailTemplate.richBody(
                text: String(parsed[run.range].characters), rtf: nil))
            let range = NSRange(location: 0, length: piece.length)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.traitBold) }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
            if !traits.isEmpty, let font = piece.attribute(.font, at: 0, effectiveRange: nil) as? UIFont,
               let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                piece.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
            }
            if let link = run.link { piece.addAttribute(.link, value: link, range: range) }
            result.append(piece)
        }
        return (result.string, MailTemplate.encodeRTF(result))
    }
}
