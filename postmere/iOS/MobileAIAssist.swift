import EventKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - One-tap replies

/// Above the reply bar: ask once for three short replies, then tap one to open it
/// in the composer, ready to edit and send.
struct MobileQuickReplyStrip: View {
    let message: MailMessage
    let conversation: [MailMessage]
    let runtime: MailRuntime
    @Environment(\.postmereAccent) private var palette
    @State private var replies: [MailQuickReply] = []
    @State private var loading = false
    @State private var error: String?

    private var store: MailStore { runtime.store }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if replies.isEmpty {
                    Button { Task { await load() } } label: {
                        Label(error ?? (loading ? "Suggesting replies…" : "Suggest replies"),
                              systemImage: error == nil ? "sparkles" : "exclamationmark.circle")
                            .font(.system(size: 13.5, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(error == nil ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.secondary))
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .disabled(loading)
                    .symbolEffect(.pulse, options: .repeating, isActive: loading)
                } else {
                    ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                        Button { store.beginReply(to: message, text: reply.text) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(reply.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.accent)
                                Text(reply.text).font(.system(size: 13.5)).lineLimit(1).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: 230, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .transition(MobileMotion.staggered(index))
                        .accessibilityLabel("\(reply.label): \(reply.text)")
                        .accessibilityHint("Opens this reply in the composer")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .disabled(MailAccount.sendingAccounts.isEmpty)
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let found = try await MailAIAssist.quickReplies(for: conversation, session: runtime.backend)
            withAnimation(MobileMotion.reveal) { replies = found }
        } catch BackendError.response(403, _) {
            error = "Turn on AI in Settings"
        } catch {
            self.error = "Couldn’t suggest replies"
        }
    }
}

// MARK: - Nudge

/// On a conversation that went quiet after the user asked something.
struct MobileNudgeCard: View {
    let message: MailMessage
    let store: MailStore
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        let days = max(1, Calendar.current.dateComponents([.day], from: message.sentAt, to: .now).day ?? 0)
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 34, height: 34)
                .background(palette.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("No reply in \(days) days").font(.subheadline.weight(.semibold))
                Text("You asked something and haven’t heard back.").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Nudge") {
                store.beginCompose(replyTo: message)
                store.pendingWriterPrompt = MailAIAssist.nudgeNotes
            }
            .buttonStyle(.glassProminent)
            .tint(palette.accent)
            .disabled(MailAccount.sendingAccounts.isEmpty)
            .accessibilityHint("Opens a reply with a short follow-up written for you")
        }
        .padding(14)
        .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Action items

/// What the user has to do because of a conversation, each one a tap away from
/// a Postmere follow-up or a reminder in Reminders.
struct MobileActionItemsSheet: View {
    let conversation: [MailMessage]
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var items: [MailActionItem]?
    @State private var error: String?
    @State private var added: Set<String> = []
    @State private var notice: String?

    private var store: MailStore { runtime.store }

    var body: some View {
        NavigationStack {
            List {
                if let items {
                    if items.isEmpty {
                        ContentUnavailableView("Nothing for you to do", systemImage: "checkmark.circle",
                                               description: Text("This conversation doesn’t ask anything of you."))
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(items) { item in row(item) }
                    } footer: {
                        if !items.isEmpty { Text("Found by AI from this conversation. Check before relying on it.") }
                    }
                    .mobileSheetRows()
                } else if let error {
                    Text(error).foregroundStyle(PostmereTheme.destructiveInk).mobileSheetRows()
                } else {
                    HStack { Spacer(); ProgressView("Reading the conversation…"); Spacer() }.listRowBackground(Color.clear)
                }
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear) }
            }
            .navigationTitle("To-Dos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
            .task { await load() }
        }
        .mobileSheetDetents()
    }

    private func row(_ item: MailActionItem) -> some View {
        let done = added.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? palette.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.body.weight(.medium))
                    if let due = item.dueAt {
                        Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !done {
                HStack(spacing: 8) {
                    Button("Remind Me", systemImage: "bell") { remindInPostmere(item) }
                    Button("Add to Reminders", systemImage: "checklist") { Task { await addToReminders(item) } }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(palette.accent)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        do { items = try await MailAIAssist.actionItems(for: conversation, session: runtime.backend) }
        catch BackendError.response(403, _) { error = "Turn on AI in Settings to find to-dos." }
        catch { self.error = error.localizedDescription }
    }

    /// A follow-up on the message the task came from, at its due time or tomorrow morning.
    private func remindInPostmere(_ item: MailActionItem) {
        guard let message = conversation.first(where: { $0.backendMessageID == item.sourceId }) ?? conversation.last else { return }
        let date = item.dueAt.map { $0.addingTimeInterval(-3_600) }.flatMap { $0 > .now ? $0 : nil } ?? Self.tomorrowMorning()
        store.setFollowUp(message.id, at: date, onlyIfNoReply: false)
        withAnimation { _ = added.insert(item.id) }
        notice = "Postmere will remind you \(date.formatted(.relative(presentation: .named)))."
    }

    private func addToReminders(_ item: MailActionItem) async {
        let events = EKEventStore()
        do {
            guard try await events.requestFullAccessToReminders() else {
                notice = "Allow Postmere to use Reminders in Settings to add to-dos there."
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

/// "What's in this file?" for a PDF or text attachment. Its text is read on the
/// device and only sent when the person asks.
struct MobileDocumentSummarySheet: View {
    let attachment: MailAttachment
    let message: MailMessage
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var summary: MailDocumentSummary?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let summary {
                    Section { Text(summary.summary).font(.body).fixedSize(horizontal: false, vertical: true) }
                        .mobileSheetRows()
                    if !summary.points.isEmpty {
                        Section("Key details") {
                            ForEach(summary.points, id: \.self) { point in
                                Label { Text(point.text) } icon: { Image(systemName: point.symbol).foregroundStyle(palette.accent) }
                            }
                        }
                        .mobileSheetRows()
                    }
                    Text("Written by AI from the file’s text. Check the file before relying on it.")
                        .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                } else if let error {
                    Text(error).foregroundStyle(PostmereTheme.destructiveInk).mobileSheetRows()
                } else {
                    HStack { Spacer(); ProgressView("Reading \(attachment.name)…"); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() } }
            }
            .task { await load() }
        }
        .mobileSheetDetents()
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

/// Before sending: real mistakes only, each fixed with a tap.
struct MobileProofreadSheet: View {
    let runtime: MailRuntime
    /// Sends after the check when the person chose Send from it.
    let onSend: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var issues: [MailProofreadIssue]?
    @State private var error: String?

    private var store: MailStore { runtime.store }

    var body: some View {
        NavigationStack {
            List {
                if let issues {
                    if issues.isEmpty {
                        ContentUnavailableView("Looks good", systemImage: "checkmark.seal",
                                               description: Text("No spelling, name or date problems found."))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(issues) { issue in
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(issue.title, systemImage: issue.symbol)
                                    .font(.footnote.weight(.semibold)).foregroundStyle(palette.accent)
                                (Text(issue.excerpt).strikethrough().foregroundStyle(.secondary)
                                 + Text("  →  ") + Text(issue.suggestion).fontWeight(.semibold))
                                    .font(.body)
                                Text(issue.explanation).font(.footnote).foregroundStyle(.secondary)
                                Button("Fix", systemImage: "wand.and.stars") { fix(issue) }
                                    .buttonStyle(.bordered).controlSize(.small).tint(palette.accent)
                                    .disabled(!store.draftBody.contains(issue.excerpt))
                            }
                            .padding(.vertical, 4)
                        }
                        .mobileSheetRows()
                    }
                } else if let error {
                    Text(error).foregroundStyle(PostmereTheme.destructiveInk).mobileSheetRows()
                } else {
                    HStack { Spacer(); ProgressView("Checking your message…"); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Proofread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "paperplane.fill") { dismiss(); onSend() }
                        .disabled(!store.canSendDraft)
                }
                if let issues, issues.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Fix All") { issues.forEach(fix) }
                    }
                }
            }
            .task { await load() }
        }
        .mobileSheetDetents()
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

/// Under the search field: turns a description into Postmere's search syntax.
struct MobileAISearchRow: View {
    let runtime: MailRuntime
    @Environment(\.postmereAccent) private var palette
    @State private var working = false
    @State private var explanation: String?
    @State private var error: String?
    @State private var applied: String?

    private var store: MailStore { runtime.store }
    private var text: String { store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Worth offering for a sentence, not for a few words or a query that already uses fields.
    static func offers(for text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count >= 3 && !text.contains(":")
    }

    var body: some View {
        content
            // Typing something new offers the AI search again.
            .onChange(of: store.searchText) {
                if store.searchText != applied { explanation = nil; error = nil }
            }
    }

    @ViewBuilder private var content: some View {
        if let explanation {
            Label(explanation, systemImage: "sparkles")
                .font(.footnote).foregroundStyle(.secondary)
        } else if Self.offers(for: text) {
            Button { Task { await translate() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(palette.accent)
                        .symbolEffect(.pulse, options: .repeating, isActive: working)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(working ? "Building the search…" : "Search with AI").font(.subheadline.weight(.semibold))
                        Text(error ?? "Turns your description into exact filters you can edit.")
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(working)
        }
    }

    private func translate() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let result = try await MailAIAssist.translateSearch(text, session: runtime.backend)
            guard MailSearchQuery(source: result.query).isValid else {
                error = "That search couldn’t be built. Try describing it differently."
                return
            }
            applied = result.query
            store.updateSearchText(result.query)
            withAnimation { explanation = result.explanation }
        } catch BackendError.response(403, _) {
            error = "Turn on AI in Settings to search this way."
        } catch { self.error = error.localizedDescription }
    }
}
