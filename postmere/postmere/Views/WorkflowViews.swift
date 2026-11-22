import SwiftUI

enum MailSchedulePurpose: String, Identifiable {
    case snooze, followUp, sendLater, composeFollowUp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .snooze: "Snooze conversation"
        case .followUp, .composeFollowUp: "Follow-up reminder"
        case .sendLater: "Send later"
        }
    }
}

struct MailScheduleSheet: View {
    let purpose: MailSchedulePurpose
    let onSave: (Date, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(purpose.title).font(PostmereTheme.sheetTitle)
            MailScheduleEditor(purpose: purpose, usesDialogShortcuts: true, onCancel: { dismiss() }) { date, conditional in
                onSave(date, conditional)
                dismiss()
            }
        }
        .padding(24).frame(width: 430)
        .mailPanelSurface()
    }
}

struct MailScheduleEditor: View {
    let purpose: MailSchedulePurpose
    let usesDialogShortcuts: Bool
    let onCancel: () -> Void
    let onSave: (Date, Bool) -> Void
    @State private var date: Date
    @State private var onlyIfNoReply: Bool

    init(purpose: MailSchedulePurpose, initialDate: Date? = nil, onlyIfNoReply: Bool = true,
         usesDialogShortcuts: Bool = false, onCancel: @escaping () -> Void,
         onSave: @escaping (Date, Bool) -> Void) {
        self.purpose = purpose
        self.usesDialogShortcuts = usesDialogShortcuts
        self.onCancel = onCancel
        self.onSave = onSave
        let now = Date.now
        _date = State(initialValue: initialDate.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(3600))
        _onlyIfNoReply = State(initialValue: onlyIfNoReply)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack { presets }.fixedSize()
                Menu("Quick dates") { presets }
            }
            .controlSize(.small)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Date and time").accessibilityHidden(true)
                    datePicker
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Date and time").accessibilityHidden(true)
                    datePicker
                }
            }
            if purpose == .followUp || purpose == .composeFollowUp {
                Toggle("Only if nobody replies", isOn: $onlyIfNoReply)
            }
            if purpose == .sendLater {
                Text("Keep Postmere open until your workspace accepts the message. Your server then delivers it at the scheduled time, even while this Mac is asleep.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(usesDialogShortcuts ? .cancelAction : nil)
                Button("Set") {
                    guard date > .now else { return }
                    onSave(date, onlyIfNoReply)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(usesDialogShortcuts ? .defaultAction : nil)
                    .disabled(date <= .now)
            }
        }
    }

    private var datePicker: some View {
        DatePicker("Date and time", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
    }

    @ViewBuilder private var presets: some View {
        Button("In one hour") { date = .now.addingTimeInterval(3600) }
        Button("Tomorrow") { date = tomorrow }
        Button("Next week") { date = Calendar.current.date(byAdding: .day, value: 6, to: tomorrow) ?? tomorrow }
    }

    private var tomorrow: Date {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: next) ?? next
    }
}

struct PrivateNoteSheet: View {
    let store: MailStore
    let message: MailMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Private note").font(PostmereTheme.sheetTitle)
            Text(message.displaySubject).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            PrivateNoteEditor(store: store, message: message, usesDialogShortcuts: true,
                              onCancel: { dismiss() }, onSave: { dismiss() })
        }
        .padding(24).frame(width: 460)
        .mailPanelSurface()
    }
}

struct PrivateNoteEditor: View {
    let store: MailStore
    let message: MailMessage
    let draft: Binding<String>?
    let usesDialogShortcuts: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @Environment(\.mailboxInset) private var inset
    @Environment(\.dismissReaderPanel) private var dismissReaderPanel
    @State private var note: String

    init(store: MailStore, message: MailMessage, draft: Binding<String>? = nil, usesDialogShortcuts: Bool = false,
         onCancel: @escaping () -> Void, onSave: @escaping () -> Void) {
        self.store = store
        self.message = message
        self.draft = draft
        self.usesDialogShortcuts = usesDialogShortcuts
        self.onCancel = onCancel
        self.onSave = onSave
        _note = State(initialValue: message.workflow.privateNote)
    }

    var body: some View {
        let text = draft ?? $note
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: text).font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: dismissReaderPanel == nil ? 180 : 36, idealHeight: 180,
                       maxHeight: dismissReaderPanel == nil ? 180 : 240)
                .accessibilityLabel("Private note")
                .padding(8)
                .background(inset, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
                .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
            Text("Only stored on this Mac. Never included in an email.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(usesDialogShortcuts ? .cancelAction : nil)
                Button("Save") {
                    store.setPrivateNote(text.wrappedValue, for: message.id)
                    onSave()
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(usesDialogShortcuts ? .defaultAction : nil)
            }
        }
    }
}

struct SavedInboxViewEditor: View {
    @Bindable var store: MailStore
    var editing: SavedInboxView?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var name = ""
    @State private var criteria = SavedInboxCriteria()
    @State private var matches: Int?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool {
        MailSearchQuery(source: criteria.query, defaultField: criteria.searchField).isValid
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Receipts, Team updates…"))
                        .focused($nameFocused)
                }
                MailCriteriaFields(criteria: $criteria)
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 520, height: 640)
        .mailPanelSurface()
        .onAppear {
            name = editing?.name ?? ""
            criteria = editing?.criteria ?? SavedInboxCriteria(query: store.searchText, account: store.selectedAccount,
                unreadOnly: store.unreadOnly, attachmentsOnly: store.attachmentsOnly,
                mailbox: store.searchScope == .allMailboxes ? nil : store.selectedMailbox)
            if editing == nil { criteria.searchField = store.searchField }
            nameFocused = true
        }
        .task(id: criteria) { await countMatches() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PostmereIcon("line.3.horizontal.decrease.circle", size: 18)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(palette.accent.gradient, in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "Save Inbox View" : "Edit Inbox View")
                    .font(PostmereTheme.sheetTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Keep this search one click away in the sidebar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                if let matches {
                    HStack(spacing: 6) {
                        Circle().fill(matches > 0 ? palette.accent : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(matches == 0 ? "No conversations match yet"
                             : matches == 1 ? "1 conversation matches" : "\(matches.formatted()) conversations match")
                            .contentTransition(.numericText(value: Double(matches)))
                    }
                } else {
                    Text(isValid ? "Counting…" : "Fix the search rule to save")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .animation(.snappy(duration: 0.2), value: matches)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save View", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || !isValid)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func save() {
        var view = editing ?? SavedInboxView(name: trimmedName, criteria: criteria)
        view.name = trimmedName
        view.criteria = criteria
        store.saveInboxView(view)
        store.selectSavedView(view)
        dismiss()
    }

    /// Counts conversations the view would show, off the main thread and
    /// shortly after typing pauses.
    private func countMatches() async {
        guard isValid else { matches = nil; return }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let matcher = store.matcher(criteria)
        let context = store.searchContext
        let visible = store.messages.filter(store.isAccountVisible)
        let count = await Task.detached(priority: .userInitiated) {
            MailSearchRequest.representatives(visible.filter { matcher.matches($0, context: context) }, preferred: nil).count
        }.value
        guard !Task.isCancelled else { return }
        matches = count
    }
}

struct OutgoingStatusView: View {
    @Environment(\.mailboxInset) private var inset
    @Bindable var store: MailStore
    let item: OutgoingMailItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(item.status == .failed ? "Delivery needs attention" : item.status == .delivering ? "Sending…" : "Scheduled to send")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(item.status == .failed ? Color.red : Color.primary)
            } icon: {
                PostmereIcon(item.status == .failed ? "exclamationmark.circle" : "clock", size: 16)
                    .foregroundStyle(item.status == .failed ? Color.red : PostmereTheme.icon)
            }
            if let error = item.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
            else if item.status == .pending {
                Text(item.scheduledAt, format: .dateTime.month().day().hour().minute()).font(.caption)
                Text(item.serverJobID != nil ? "Your server will deliver this message while Postmere is closed."
                     : item.submissionStarted == true ? "Waiting for server confirmation. Keep Postmere open."
                     : "Keep Postmere open until your workspace accepts this message.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if item.status == .failed && item.serverState != "uncertain" { Button("Retry Send") { store.retrySend(item.id) } }
                if item.status != .delivering && item.serverState != "uncertain" { Button("Cancel Send and Edit") { store.cancelQueuedSend(item.id) } }
            }.controlSize(.small)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(inset, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
    }
}
