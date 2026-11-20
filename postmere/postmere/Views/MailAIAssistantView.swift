import SwiftUI

struct MailAIAssistantView: View {
    @Environment(\.mailboxInset) private var inset
    @Environment(\.postmereAccent) private var palette
    let runtime: MailRuntime
    let mode: MailAIMode
    var messages: [MailMessage] = []
    var draftText = ""
    var onApplyText: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var settings: MailAISettings?
    @State private var result: MailAIResult?
    @State private var error: String?
    @State private var busy = false
    @State private var question = ""
    @State private var instruction = "reply"
    @State private var notes = ""
    @State private var selectedAccountID: UUID?
    @State private var applied: Set<Int> = []
    @State private var undoAction: (() -> Void)?

    private var sourceIDs: [UUID] { Array(Set(messages.filter { $0.mailAccount.remote?.scope == runtime.backend.scope }.compactMap(\.backendMessageID))).prefix(30).map { $0 } }

    var body: some View {
        VStack(spacing: 0) {
            PostmereSheetHeader(mode.title)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !runtime.backend.isConnected {
                        Text("Connect your Postmere workspace in Settings → Accounts to use AI assistance.").foregroundStyle(.secondary)
                    } else if let settings, !settings.enabled || !settings.available {
                        Text(settings.dataNotice).font(.system(size: 13)).foregroundStyle(.secondary)
                        if !settings.available { Text("Your server administrator needs to configure an AI provider.").font(.caption).foregroundStyle(.secondary) }
                        else { Button("Enable AI for My Workspace Account") { Task { await enable() } }.disabled(busy) }
                    } else if settings != nil {
                        inputs
                        if let result { output(result) }
                        else { Text("AI suggestions can be wrong. Review the result and its source messages before using it.").font(.caption).foregroundStyle(.secondary) }
                    } else if error == nil {
                        ProgressView("Loading AI settings…").controlSize(.small)
                    }
                    if busy { ProgressView("Working…").controlSize(.small) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result, mode == .draft {
                Divider()
                HStack {
                    Text("Replaces the draft body. You can undo this change.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use in Draft") { onApplyText?(result.text); close() }
                        .buttonStyle(.borderedProminent).disabled(onApplyText == nil || busy)
                }.padding(18)
            }
        }.frame(width: 640, height: 650)
            .task {
                guard runtime.backend.isConnected else { return }
                do { settings = try await runtime.backend.request("GET", "/v1/ai/settings") }
                catch { self.error = error.localizedDescription }
                selectedAccountID = runtime.store.selectedAccount.flatMap(MailAccount.init(rawValue:))?.remote?.accountID
                if !draftText.isEmpty { instruction = "clarify" }
            }
    }

    @ViewBuilder private var inputs: some View {
        if mode == .ask {
            Picker("Search", selection: $selectedAccountID) {
                Text("All connected accounts").tag(Optional<UUID>.none)
                ForEach(runtime.backend.accounts) { Text($0.email).tag(Optional($0.id)) }
            }
            TextField("Ask about a project, person, or decision", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
            Text("Searches mail synced to your server. Answers use up to 20 matching messages; calendar and unsynced history are excluded.")
                .font(.caption).foregroundStyle(.secondary)
        } else if mode == .draft {
            Picker("Action", selection: $instruction) {
                Text("Draft a reply").tag("reply"); Text("Shorten").tag("shorten"); Text("Clarify").tag("clarify")
                Text("More friendly").tag("friendly"); Text("More formal").tag("formal"); Text("Expand notes").tag("expand")
            }
            TextField("What would you like to say?", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...6)
            Text("Uses your draft and \(sourceIDs.count) selected message\(sourceIDs.count == 1 ? "" : "s"). Attachments are excluded.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Uses \(sourceIDs.count) selected message\(sourceIDs.count == 1 ? "" : "s") from this conversation.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button(result == nil ? "Generate" : "Generate Again") { Task { await generate() } }
            .buttonStyle(.borderedProminent).disabled(busy || (mode == .ask && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                || (mode == .suggestions && sourceIDs.isEmpty))
    }

    private func output(_ result: MailAIResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text("AI suggestion").font(.caption.weight(.medium)).foregroundStyle(palette.accentInk)
            Text(result.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(result.items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.kind.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(item.text).font(.system(size: 13)).textSelection(.enabled)
                    ForEach(result.sources.filter { item.sourceIds.contains($0.id) }) { source in
                        Button { Task { await open(source) } } label: {
                            PostmereLabel(MailMessage.displaySubject(source.subject), symbol: "envelope", size: 12).font(.caption).lineLimit(1)
                        }.buttonStyle(.borderless)
                    }
                    if let action = item.action, mode == .suggestions {
                        Button(applied.contains(index) ? "Applied" : actionTitle(action)) { apply(item, index: index) }
                            .disabled(applied.contains(index) || (action == "follow_up" && item.dueAt == nil))
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(inset, in: .rect(cornerRadius: PostmereTheme.cardRadius))
            }
            if undoAction != nil { Button("Undo Last Suggestion") { undoAction?(); undoAction = nil; applied = [] } }
            Text(result.scope).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func enable() async {
        busy = true; error = nil
        defer { busy = false }
        do { settings = try await runtime.backend.request("PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: true, styleGuide: settings?.styleGuide ?? "")) }
        catch { self.error = error.localizedDescription }
    }
    private func generate() async {
        busy = true; error = nil; result = nil; applied = []; undoAction = nil
        defer { busy = false }
        do {
            switch mode {
            case .suggestions:
                result = try await runtime.backend.request("POST", "/v1/ai/\(mode.rawValue)", body: MailAISourceInput(messageIds: sourceIDs))
            case .draft:
                result = try await runtime.backend.request("POST", "/v1/ai/draft", body: MailAIDraftInput(messageIds: sourceIDs, draftText: draftText, instruction: instruction, notes: notes))
            case .ask:
                result = try await runtime.backend.request("POST", "/v1/ai/ask", body: MailAIAskInput(question: question, accountIds: selectedAccountID.map { [$0] } ?? []))
            }
        } catch { self.error = error.localizedDescription }
    }
    private func open(_ source: MailAISource) async {
        do {
            guard let identity = RemoteAccountRegistry.accounts.first(where: { $0.accountID == source.accountId && $0.scope == runtime.backend.scope }) else { throw BackendError.notConnected }
            let message = try await runtime.fetchProviderMessage(source.id, for: identity)
            runtime.store.selectAccount(message.account)
            runtime.store.selectedInboxSplitID = nil
            runtime.store.selectedMailbox = message.mailbox
            runtime.store.select(message)
            close()
        } catch { self.error = error.localizedDescription }
    }
    private func actionTitle(_ action: String) -> String {
        switch action { case "archive": "Archive"; case "follow_up": "Set Follow-up"; default: "Add to Needs Reply" }
    }
    private func apply(_ item: MailAIItem, index: Int) {
        guard let targetID = item.messageId, item.sourceIds.contains(targetID),
              let message = runtime.store.messages.first(where: { $0.backendMessageID == targetID && $0.mailAccount.remote?.scope == runtime.backend.scope }) else { return }
        switch item.action {
        case "needs_reply":
            runtime.store.setNeedsReply(true, for: message.id)
            undoAction = { runtime.store.setNeedsReply(message.workflow.needsReply, for: message.id) }
        case "archive":
            runtime.store.moveMessages([message.id], to: .archive)
            undoAction = runtime.store.undoLastMove
        case "follow_up":
            guard let date = item.dueAt else { return }
            runtime.store.setFollowUp(message.id, at: date, onlyIfNoReply: true)
            undoAction = {
                if let previous = message.workflow.followUpAt { runtime.store.setFollowUp(message.id, at: previous, onlyIfNoReply: message.workflow.followUpOnlyIfNoReply) }
                else { runtime.store.clearFollowUp(message.id) }
            }
        default: return
        }
        applied.insert(index)
    }
}
