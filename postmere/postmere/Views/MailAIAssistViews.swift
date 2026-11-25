import EventKit
import SwiftUI

// The Mac's one-tap replies, nudges, to-dos, file summaries, proofreading and
// AI search. The requests and their checks live in MailAIAssist, shared with iPhone.

// MARK: - One-tap replies

struct MailQuickReplyStrip: View {
    let message: MailMessage
    let conversation: [MailMessage]
    let runtime: MailRuntime
    /// Opens the composer after the reply is set up.
    let openComposer: () -> Void
    @Environment(\.postmereAccent) private var palette
    @State private var replies: [MailQuickReply] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 8) {
            if replies.isEmpty {
                Button { Task { await load() } } label: {
                    Label(error ?? (loading ? "Suggesting replies…" : "Suggest Replies"),
                          systemImage: error == nil ? "sparkles" : "exclamationmark.circle")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(palette.accentInk)
                .disabled(loading)
                .help("Suggest three short replies with AI")
            } else {
                ForEach(replies) { reply in
                    Button {
                        runtime.store.beginReply(to: message, text: reply.text)
                        openComposer()
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reply.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accentInk)
                            Text(reply.text).font(.system(size: 12.5)).lineLimit(1)
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .help(reply.text)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(MailAccount.sendingAccounts.isEmpty || runtime.store.isComposing)
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let found = try await MailAIAssist.quickReplies(for: conversation, session: runtime.backend)
            withAnimation(.smooth) { replies = found }
        } catch BackendError.response(403, _) {
            error = "Turn on AI in Settings"
        } catch {
            self.error = "Couldn’t suggest replies"
        }
    }
}

// MARK: - Nudge

struct MailNudgeBanner: View {
    let message: MailMessage
    let store: MailStore
    let openComposer: () -> Void
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        let days = max(1, Calendar.current.dateComponents([.day], from: message.sentAt, to: .now).day ?? 0)
        HStack(spacing: 10) {
            Image(systemName: "hourglass").foregroundStyle(palette.accentInk)
            Text("No reply in \(days) days to your question.").font(.callout)
            Spacer(minLength: 8)
            Button("Nudge") {
                store.beginCompose(replyTo: message)
                store.pendingWriterPrompt = MailAIAssist.nudgeNotes
                openComposer()
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .disabled(MailAccount.sendingAccounts.isEmpty || store.isComposing)
            .help("Reply with a short follow-up written for you")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Action items

struct MailActionItemsSheet: View {
    let conversation: [MailMessage]
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var items: [MailActionItem]?
    @State private var error: String?
    @State private var added: Set<String> = []
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("To-Dos").font(PostmereTheme.sheetTitle)
            if let items {
                if items.isEmpty {
                    Label("This conversation doesn’t ask anything of you.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { item in row(item) }
                    }
                }
                if !items.isEmpty {
                    Text("Found by AI from this conversation. Check before relying on it.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(PostmereTheme.destructiveInk)
            } else {
                ProgressView("Reading the conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 480, height: 420)
        .task { await load() }
    }

    private func row(_ item: MailActionItem) -> some View {
        let done = added.contains(item.id)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? palette.accentInk : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium))
                if let due = item.dueAt {
                    Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !done {
                    HStack {
                        Button("Remind Me") { remind(item) }
                        Button("Add to Reminders") { Task { await addToReminders(item) } }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func load() async {
        do { items = try await MailAIAssist.actionItems(for: conversation, session: runtime.backend) }
        catch BackendError.response(403, _) { error = "Turn on AI in Settings to find to-dos." }
        catch { self.error = error.localizedDescription }
    }

    private func remind(_ item: MailActionItem) {
        guard let message = conversation.first(where: { $0.backendMessageID == item.sourceId }) ?? conversation.last else { return }
        let date = item.dueAt.map { $0.addingTimeInterval(-3_600) }.flatMap { $0 > .now ? $0 : nil } ?? Self.tomorrowMorning()
        runtime.store.setFollowUp(message.id, at: date, onlyIfNoReply: false)
        withAnimation { _ = added.insert(item.id) }
        notice = "Postmere will remind you \(date.formatted(.relative(presentation: .named)))."
    }

    private func addToReminders(_ item: MailActionItem) async {
        let events = EKEventStore()
        do {
            guard try await events.requestFullAccessToReminders() else {
                notice = "Allow Postmere to use Reminders in System Settings to add to-dos there."
                return
            }
            let reminder = EKReminder(eventStore: events)
            reminder.title = item.title
            reminder.calendar = events.defaultCalendarForNewReminders()
            if let message = conversation.first(where: { $0.backendMessageID == item.sourceId }) {
                reminder.notes = "From “\(message.displaySubject)” · \(message.sender)"
            }
            if let due = item.dueAt {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due.addingTimeInterval(-3_600)))
            }
            try events.save(reminder, commit: true)
            withAnimation { _ = added.insert(item.id) }
            notice = "Added to Reminders."
        } catch {
            notice = "Couldn’t add to Reminders: \(error.localizedDescription)"
        }
    }

    static func tomorrowMorning() -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

// MARK: - Attachment summary

struct MailDocumentSummarySheet: View {
    let attachment: MailAttachment
    let message: MailMessage
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var summary: MailDocumentSummary?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(attachment.name).font(PostmereTheme.sheetTitle).lineLimit(1).truncationMode(.middle)
            if let summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(summary.summary).textSelection(.enabled)
                        ForEach(summary.points, id: \.self) { point in
                            Label { Text(point.text).textSelection(.enabled) } icon: {
                                Image(systemName: point.symbol).foregroundStyle(palette.accentInk)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Written by AI from the file’s text. Check the file before relying on it.").font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).foregroundStyle(PostmereTheme.destructiveInk)
                Spacer()
            } else {
                ProgressView("Reading \(attachment.name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 520, height: 460)
        .task { await load() }
    }

    private func load() async {
        do {
            let resolved = try await runtime.resolveAttachment(attachment, in: message)
            guard let url = resolved.localURL, let text = await MailDocumentText.extract(from: url), !text.isEmpty else {
                error = "Postmere can’t read text from this file. Summaries work with PDFs and text files."
                return
            }
            summary = try await MailAIAssist.summarizeDocument(text: text, filename: attachment.name, message: message,
                                                               session: runtime.backend)
        } catch BackendError.response(403, _) {
            error = "Turn on AI in Settings to summarize files."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Proofread

struct MailProofreadSheet: View {
    let runtime: MailRuntime
    let onSend: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var issues: [MailProofreadIssue]?
    @State private var error: String?

    private var store: MailStore { runtime.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Proofread").font(PostmereTheme.sheetTitle)
            if let issues {
                if issues.isEmpty {
                    Label("Looks good. No spelling, name or date problems found.", systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(issues) { issue in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(issue.title, systemImage: issue.symbol)
                                        .font(.caption.weight(.semibold)).foregroundStyle(palette.accentInk)
                                    (Text(issue.excerpt).strikethrough().foregroundStyle(.secondary)
                                     + Text("  →  ") + Text(issue.suggestion).fontWeight(.semibold))
                                    Text(issue.explanation).font(.caption).foregroundStyle(.secondary)
                                    Button("Fix") { fix(issue) }.controlSize(.small)
                                        .disabled(!store.draftBody.contains(issue.excerpt))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(PostmereTheme.destructiveInk)
                Spacer()
            } else {
                ProgressView("Checking your message…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let issues, issues.count > 1 { Button("Fix All") { issues.forEach(fix) } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") { dismiss(); onSend() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canSendDraft)
            }
        }
        .padding(22)
        .frame(width: 520, height: 460)
        .task { await load() }
    }

    private func load() async {
        let recipients = (store.draftTo + "," + store.draftCc).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let conversation = store.draftConversationID
        let context = store.draftInReplyTo == nil ? [] : store.messages.filter { $0.conversationID == conversation && !$0.isDraft }
        do {
            issues = try await MailAIAssist.proofread(draft: store.draftBody, subject: store.draftSubject, recipients: recipients,
                                                      context: context, session: runtime.backend)
        } catch BackendError.response(403, _) {
            error = "Turn on AI in Settings to proofread."
        } catch { self.error = error.localizedDescription }
    }

    private func fix(_ issue: MailProofreadIssue) {
        guard let range = store.draftBody.range(of: issue.excerpt) else { return }
        store.draftBody.replaceSubrange(range, with: issue.suggestion)
        store.draftBodyRTF = nil
        withAnimation { issues?.removeAll { $0.id == issue.id } }
    }
}

// MARK: - Plain-English search

struct MailAISearchButton: View {
    let runtime: MailRuntime
    @Environment(\.postmereAccent) private var palette
    @State private var working = false
    @State private var note: String?
    @State private var applied: String?

    private var store: MailStore { runtime.store }
    private var text: String { store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 8) {
            if let note {
                Label(note, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if text.split(whereSeparator: \.isWhitespace).count >= 3 && !text.contains(":") {
                Button { Task { await translate() } } label: {
                    Label(working ? "Building the search…" : "Search with AI", systemImage: "sparkles")
                }
                .buttonStyle(.link)
                .tint(palette.accentInk)
                .disabled(working)
                .help("Turn this description into exact search filters")
            }
        }
        .onChange(of: store.searchText) { if store.searchText != applied { note = nil } }
    }

    private func translate() async {
        working = true
        defer { working = false }
        do {
            let result = try await MailAIAssist.translateSearch(text, session: runtime.backend)
            guard MailSearchQuery(source: result.query).isValid else {
                note = "That search couldn’t be built. Try describing it differently."
                return
            }
            applied = result.query
            store.updateSearchText(result.query)
            note = result.explanation
        } catch BackendError.response(403, _) {
            note = "Turn on AI in Settings to search this way."
        } catch { note = error.localizedDescription }
    }
}

// MARK: - Settings

/// Learned style and labels described in words, inside the Mac's AI settings.
struct MailAIAssistSettings: View {
    let runtime: MailRuntime
    @Binding var settings: MailAISettings?
    @State private var learning = false
    @State private var error: String?
    @State private var editing: MailDescribedLabel?

    private var labels: MailDescribedLabels { runtime.describedLabels }

    var body: some View {
        Section {
            if let learned = settings?.learnedStyle, !learned.isEmpty {
                Text(learned).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button(learning ? "Learning…" : "Learn Again") { Task { await learn() } }.disabled(learning)
                    Button("Forget", role: .destructive) { Task { await forget() } }
                }
            } else {
                Button(learning ? "Reading your sent mail…" : "Learn From My Sent Mail") { Task { await learn() } }
                    .disabled(learning)
            }
            if let error { Text(error).font(.caption).foregroundStyle(PostmereTheme.destructiveInk) }
        } header: {
            Text("Your voice")
        } footer: {
            Text("Reads up to 25 messages you’ve sent, only your own words, so replies and drafts sound like you. Your own style guidance takes priority.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            ForEach(labels.labels) { label in
                HStack {
                    Image(systemName: "tag").foregroundStyle(label.enabled ? .primary : .secondary)
                    VStack(alignment: .leading) {
                        Text(label.labelName).fontWeight(.medium)
                        Text(label.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Toggle("Sort", isOn: Binding(get: { label.enabled }, set: { enabled in
                        var updated = labels.labels
                        if let index = updated.firstIndex(where: { $0.id == label.id }) { updated[index].enabled = enabled }
                        labels.save(updated)
                    })).labelsHidden()
                    Button("Edit") { editing = label }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        labels.save(labels.labels.filter { $0.id != label.id })
                    }
                    .labelStyle(.iconOnly)
                }
            }
            Button("Add Label…") { editing = MailDescribedLabel(id: UUID().uuidString, labelName: "", description: "") }
            if let problem = labels.problem { Text(problem).font(.caption).foregroundStyle(PostmereTheme.destructiveInk) }
        } header: {
            Text("Labels you describe")
        } footer: {
            Text("Describe a label, like “Receipts and invoices”, and new mail that fits gets that label. Postmere sends the subject and the start of each new message to your workspace’s AI to decide. Kept on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { label in
            DescribedLabelEditor(label: label) { saved in
                var updated = labels.labels
                if let index = updated.firstIndex(where: { $0.id == saved.id }) { updated[index] = saved } else { updated.append(saved) }
                labels.save(updated)
            }
        }
    }

    private func learn() async {
        learning = true
        defer { learning = false }
        do {
            let learned = try await MailAIAssist.learnStyle(session: runtime.backend)
            settings?.learnedStyle = learned.learnedStyle
            settings?.learnedAt = learned.learnedAt
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func forget() async {
        guard let current = settings else { return }
        do {
            settings = try await runtime.backend.request("PUT", "/v1/ai/settings", body: MailAISettingsInput(
                enabled: current.enabled, styleGuide: current.styleGuide, learnedStyle: ""))
        } catch { self.error = error.localizedDescription }
    }
}

private struct DescribedLabelEditor: View {
    @State var label: MailDescribedLabel
    let onSave: (MailDescribedLabel) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label.labelName.isEmpty ? "New Label" : label.labelName).font(PostmereTheme.sheetTitle)
            TextField("Label name, for example Receipts", text: $label.labelName)
            TextField("What goes in it: receipts, invoices and payment confirmations…", text: $label.description, axis: .vertical)
                .lineLimit(3...6)
            Toggle("Sort new mail into this label", isOn: $label.enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    label.labelName = label.labelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    label.description = label.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(label)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.labelName.trimmingCharacters(in: .whitespaces).isEmpty
                          || label.description.trimmingCharacters(in: .whitespaces).count < 8)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 460)
    }
}
