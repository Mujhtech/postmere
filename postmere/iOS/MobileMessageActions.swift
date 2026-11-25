import SwiftUI

// MARK: - Presenting

/// A task that needs its own sheet, started from a menu, a swipe or the reader.
enum MobileTask: Identifiable {
    case snooze(Set<UUID>)
    case followUp(MailMessage)
    case note(MailMessage)
    case labels(MailMessage)
    case sendLater
    case composeFollowUp

    var id: String {
        switch self {
        case .snooze(let ids): "snooze-" + ids.map(\.uuidString).sorted().joined()
        case .followUp(let message): "follow-" + message.id.uuidString
        case .note(let message): "note-" + message.id.uuidString
        case .labels(let message): "labels-" + message.id.uuidString
        case .sendLater: "send-later"
        case .composeFollowUp: "compose-follow-up"
        }
    }
}

/// Owned by the mailbox and shared through the environment, so any screen can open a task sheet.
@MainActor @Observable
final class MobilePresenter {
    var task: MobileTask?
}

/// The sheet for each task.
struct MobileTaskSheet: View {
    let task: MobileTask
    let runtime: MailRuntime
    private var store: MailStore { runtime.store }

    var body: some View {
        switch task {
        case .snooze(let ids):
            MobileScheduleSheet(purpose: .snooze) { date, _ in
                if ids.count == 1, let id = ids.first { store.snoozeMessage(id, until: date) }
                else { store.snoozeMessages(ids, until: date) }
            }
        case .followUp(let message):
            MobileScheduleSheet(purpose: .followUp, initial: message.workflow.followUpAt,
                                onlyIfNoReply: message.workflow.followUpOnlyIfNoReply) { date, onlyIfNoReply in
                store.setFollowUp(message.id, at: date, onlyIfNoReply: onlyIfNoReply)
            }
        case .note(let message):
            MobilePrivateNoteSheet(store: store, message: message)
        case .labels(let message):
            MobileLabelsSheet(runtime: runtime, message: message)
        case .sendLater:
            MobileScheduleSheet(purpose: .sendLater, initial: store.draftSendAt) { date, _ in
                store.draftSendAt = date
            }
        case .composeFollowUp:
            MobileScheduleSheet(purpose: .followUp, initial: store.draftFollowUpAt,
                                onlyIfNoReply: store.draftFollowUpOnlyIfNoReply) { date, onlyIfNoReply in
                store.draftFollowUpAt = date
                store.draftFollowUpOnlyIfNoReply = onlyIfNoReply
            }
        }
    }
}

// MARK: - The message menu

/// Every action for one message, in the order the Mac lists them. Used by the
/// row's long-press menu and the reader's More menu.
struct MobileMessageMenu: View {
    let message: MailMessage
    let store: MailStore
    var includesReply = true
    var onRemove: () -> Void = {}
    @Environment(MobilePresenter.self) private var presenter

    var body: some View {
        if message.mailbox == .outbox {
            outboxActions
        } else {
            if message.mailbox == .trash {
                Button("Restore to \(store.restoreDestination(for: message).title)", systemImage: "arrow.uturn.backward") {
                    store.restoreMessage(message.id)
                    onRemove()
                }
            }
            if message.mailbox == .drafts {
                Button("Edit Draft", systemImage: "square.and.pencil") { store.beginEditingDraft(message) }
            } else if includesReply, !MailAccount.sendingAccounts.isEmpty {
                // A row of icons across the top of the menu, as in Mail.
                ControlGroup {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { store.beginCompose(replyTo: message) }
                    if store.hasReplyAllRecipients(for: message) {
                        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { store.beginReplyAll(message) }
                    }
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { store.beginForward(message) }
                }
                .controlGroupStyle(.compactMenu)
            }
            Section {
                Button(message.isUnread ? "Mark as Read" : "Mark as Unread",
                       systemImage: message.isUnread ? "envelope.open" : "envelope.badge") {
                    store.toggleRead(message.id)
                    if !message.isUnread { onRemove() }
                }
                Button(message.isStarred ? "Remove Star" : "Star", systemImage: message.isStarred ? "star.slash" : "star") {
                    store.toggleStar(message.id)
                }
            }
            if message.allowsWorkflowActions && message.mailbox != .trash {
                Section {
                    Button(message.needsReply ? "Mark Done" : "Needs Reply",
                           systemImage: message.needsReply ? "checkmark.circle" : "arrowshape.turn.up.left.circle") {
                        store.setNeedsReply(!message.needsReply, for: message.id)
                    }
                    if message.workflow.snoozedUntil != nil {
                        Button("Return to Inbox", systemImage: "tray.and.arrow.down") { store.unsnoozeMessage(message.id) }
                    } else {
                        Button("Snooze…", systemImage: "moon.zzz") { presenter.task = .snooze([message.id]) }
                    }
                    Button("Follow-up Reminder…", systemImage: "bell") { presenter.task = .followUp(message) }
                    if message.workflow.followUpAt != nil {
                        Button("Clear Follow-up", systemImage: "bell.slash") { store.clearFollowUp(message.id) }
                    }
                    Button(message.workflow.privateNote.isEmpty ? "Add Private Note…" : "Edit Private Note…",
                           systemImage: "note.text") { presenter.task = .note(message) }
                    if message.mailAccount.isConnected, message.backendMessageID != nil {
                        Button(message.mailAccount.remote?.provider == "microsoft" ? "Categories…" : "Labels…",
                               systemImage: "tag") { presenter.task = .labels(message) }
                    }
                }
                if message.workflow.screeningState == .pending { screening }
            }
            Section {
                if !message.isDraft {
                    Menu("Move To", systemImage: "folder") {
                        ForEach([Mailbox.inbox, .archive, .junk]) { mailbox in
                            Button(mailbox.title, systemImage: mailbox.mobileSymbol) {
                                store.moveMessage(message.id, to: mailbox)
                                onRemove()
                            }
                            .disabled(!store.canMoveMessage(message, to: mailbox))
                        }
                    }
                }
                if store.canMoveMessage(message, to: .trash) {
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        store.moveMessage(message.id, to: .trash)
                        onRemove()
                    }
                }
            }
        }
    }

    @ViewBuilder private var outboxActions: some View {
        if let item = store.outgoingQueue.first(where: { $0.id == message.id }) {
            if item.status == .failed {
                Button("Retry Send", systemImage: "arrow.clockwise") { store.retrySend(item.id) }
            }
            if item.status == .pending && item.undoUntil > .now {
                Button("Undo Send", systemImage: "arrow.uturn.backward") { store.undoSend(item.id) }
            }
            Button("Cancel Send and Edit", systemImage: "square.and.pencil") { store.cancelQueuedSend(item.id) }
                .disabled(item.status == .delivering)
        }
    }

    @ViewBuilder private var screening: some View {
        Section("New sender") {
            Menu("Accept Sender", systemImage: "person.badge.plus") {
                ForEach([SenderRoute.inbox, .archive, .needsReply]) { route in
                    Button(route.title) { store.acceptSender(of: message, route: route) }
                }
                if let domain = WebsiteIconDomains.shared.organization(for: message.senderEmail) {
                    Divider()
                    Button("Everyone at \(domain)") { store.acceptDomain(domain, of: message) }
                }
            }
            Button("Block Sender", systemImage: "hand.raised", role: .destructive) {
                store.blockSender(of: message)
                onRemove()
            }
        }
    }
}

// MARK: - Scheduling

enum MobileSchedulePurpose {
    case snooze, followUp, sendLater

    var title: String {
        switch self {
        case .snooze: "Snooze until"
        case .followUp: "Remind me"
        case .sendLater: "Send later"
        }
    }

    var symbol: String {
        switch self {
        case .snooze: "moon.zzz.fill"
        case .followUp: "bell.fill"
        case .sendLater: "paperplane.fill"
        }
    }
}

/// Quick times first, then a calendar for anything else.
struct MobileScheduleSheet: View {
    let purpose: MobileSchedulePurpose
    let onSave: (Date, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var date: Date
    @State private var onlyIfNoReply: Bool
    @State private var picksDate = false

    init(purpose: MobileSchedulePurpose, initial: Date? = nil, onlyIfNoReply: Bool = true,
         onSave: @escaping (Date, Bool) -> Void) {
        self.purpose = purpose
        self.onSave = onSave
        let now = Date.now
        _date = State(initialValue: initial.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(3600))
        _onlyIfNoReply = State(initialValue: onlyIfNoReply)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(presets, id: \.title) { preset in
                        Button { save(preset.date) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: preset.symbol)
                                    .font(.system(size: 17))
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 26)
                                Text(preset.title).foregroundStyle(.primary)
                                Spacer()
                                Text(preset.date.mobileScheduleLabel)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .mobileSheetRows()
                Section {
                    Button {
                        withAnimation(.snappy) { picksDate.toggle() }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "calendar")
                                .font(.system(size: 17))
                                .foregroundStyle(palette.accent)
                                .frame(width: 26)
                            Text("Pick date and time").foregroundStyle(.primary)
                            Spacer()
                            if picksDate {
                                Text(date.mobileScheduleLabel).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if picksDate {
                        DatePicker("Date and time", selection: $date, in: Date.now...,
                                   displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .tint(palette.accent)
                    }
                }
                .mobileSheetRows()
                if purpose == .followUp {
                    Section {
                        Toggle("Only if nobody replies", isOn: $onlyIfNoReply).tint(palette.accent)
                    }
                    .mobileSheetRows()
                }
                if purpose == .sendLater {
                    Section {
                    } footer: {
                        Text("Your server delivers the message at the scheduled time, even when your phone is off.")
                    }
                    .mobileSheetRows()
                }
            }
            .listSectionSpacing(14)
            .navigationTitle(purpose.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                if picksDate {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Set", systemImage: "checkmark") { save(date) }
                            .buttonStyle(.glassProminent)
                            .tint(palette.accent)
                            .disabled(date <= .now)
                    }
                }
            }
        }
        .presentationDetents(picksDate ? [.large] : [.medium, .large])
        .mobileSheetSurface()
    }

    private func save(_ date: Date) {
        guard date > .now else { return }
        onSave(date, onlyIfNoReply)
        dismiss()
    }

    private struct Preset {
        let title: String
        let symbol: String
        let date: Date
    }

    private var presets: [Preset] {
        let calendar = Calendar.current
        let now = Date.now
        func at(_ hour: Int, daysFromNow days: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        var result: [Preset] = []
        let hour = calendar.component(.hour, from: now)
        if hour < 17 {
            let later = calendar.date(byAdding: .hour, value: 3, to: now) ?? now
            let rounded = calendar.date(bySetting: .minute, value: 0, of: later) ?? later
            result.append(Preset(title: "Later today", symbol: "clock", date: rounded))
            result.append(Preset(title: "This evening", symbol: "moon", date: at(18, daysFromNow: 0)))
        } else {
            result.append(Preset(title: "In an hour", symbol: "clock", date: now.addingTimeInterval(3600)))
        }
        result.append(Preset(title: "Tomorrow morning", symbol: "sunrise", date: at(9, daysFromNow: 1)))
        let weekday = calendar.component(.weekday, from: now)
        if weekday != 7 && weekday != 1 {
            result.append(Preset(title: "This weekend", symbol: "sofa", date: at(9, daysFromNow: 7 - weekday)))
        }
        let toMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        result.append(Preset(title: "Next week", symbol: "calendar.badge.clock", date: at(9, daysFromNow: toMonday)))
        return result
    }
}

extension Date {
    /// "Today 18:00", "Tomorrow 09:00", "Sat 09:00" or "3 Dec 09:00".
    var mobileScheduleLabel: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) { return "Today \(time)" }
        if calendar.isDateInTomorrow(self) { return "Tomorrow \(time)" }
        if let days = calendar.dateComponents([.day], from: .now, to: self).day, days < 6 {
            return formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        return formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }
}

// MARK: - Private note

struct MobilePrivateNoteSheet: View {
    let store: MailStore
    let message: MailMessage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var note: String
    @FocusState private var focused: Bool

    init(store: MailStore, message: MailMessage) {
        self.store = store
        self.message = message
        _note = State(initialValue: message.workflow.privateNote)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(message.displaySubject)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                TextEditor(text: $note)
                    .font(.system(size: 17))
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Private note")
                Text("Only you can see this. It's never included in an email.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(Mobile.gutter)
            .navigationTitle("Private note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        store.setPrivateNote(note, for: message.id)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(palette.accent)
                }
            }
            .task { focused = true }
        }
        .mobileSheetDetents()
    }
}

// MARK: - Labels

/// Gmail labels or Outlook categories, searchable, with "Create" for a new name.
struct MobileLabelsSheet: View {
    let runtime: MailRuntime
    let message: MailMessage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var editor: MessageLabelEditor
    @State private var refreshRevision = 0

    init(runtime: MailRuntime, message: MailMessage) {
        self.runtime = runtime
        self.message = message
        _editor = State(initialValue: MessageLabelEditor(runtime: runtime, message: message))
    }

    var body: some View {
        @Bindable var editor = editor
        NavigationStack {
            List {
                if editor.canCreate {
                    Button {
                        Task { await editor.createAndApply() }
                    } label: {
                        Label("Create “\(editor.name)”", systemImage: "plus.circle.fill")
                            .foregroundStyle(palette.accent)
                    }
                    .disabled(editor.busy || !editor.confirmed)
                }
                if editor.selection != nil {
                    ForEach(editor.visibleLabels) { label in
                        let applied = editor.isApplied(label)
                        Button {
                            Task { await editor.update(label: label, applied: !applied) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(applied ? palette.accent : Color(uiColor: .tertiaryLabel))
                                    .frame(width: 22)
                                Text(label.name).foregroundStyle(.primary)
                                Spacer()
                                if applied {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(palette.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(editor.busy || !editor.confirmed)
                        .accessibilityAddTraits(applied ? .isSelected : [])
                    }
                    if editor.visibleLabels.isEmpty && editor.name.isEmpty {
                        Text(editor.outlook ? "Type a name to create your first category." : "Type a name to create your first label.")
                            .foregroundStyle(.secondary)
                    }
                } else if editor.error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
                if let error = editor.error {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        if !editor.needsReconnect {
                            Button("Try Again") { refreshRevision += 1 }.disabled(editor.busy)
                        }
                    }
                    .mobileSheetRows()
                }
            }
            .searchable(text: $editor.search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: editor.outlook ? "Find or create a category" : "Find or create a label")
            .navigationTitle(editor.outlook ? "Categories" : "Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if editor.busy && editor.selection != nil {
                        ProgressView()
                    } else {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
            .task(id: refreshRevision) { await editor.refresh() }
        }
        .mobileSheetDetents()
    }
}

// MARK: - Outbox

/// What's happening to an outgoing message, with retry and cancel.
struct MobileOutgoingStatus: View {
    let store: MailStore
    let item: OutgoingMailItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(item.status == .failed ? "Delivery needs attention"
                     : item.status == .delivering ? "Sending…" : "Scheduled to send")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: item.status == .failed ? "exclamationmark.circle.fill" : "clock.fill")
            }
            .foregroundStyle(item.status == .failed ? AnyShapeStyle(PostmereTheme.destructiveInk) : AnyShapeStyle(.primary))
            if let error = item.lastError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            } else if item.status == .pending {
                Text(item.scheduledAt.mobileScheduleLabel).font(.footnote.weight(.medium))
                Text(item.serverJobID != nil ? "Your server will deliver this message, even if your phone is off."
                     : "Waiting for your server to accept this message.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if item.status == .failed && item.serverState != "uncertain" {
                    Button("Retry Send") { store.retrySend(item.id) }
                        .buttonStyle(.glassProminent)
                }
                if item.status != .delivering && item.serverState != "uncertain" {
                    Button("Cancel and Edit") { store.cancelQueuedSend(item.id) }
                        .buttonStyle(.glass)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
