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
    @State private var name = ""
    @State private var criteria = SavedInboxCriteria()

    var body: some View {
        VStack(spacing: 0) {
            Text(editing == nil ? "Save inbox view" : "Edit inbox view")
                .font(PostmereTheme.sheetTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 24)
            Form {
                Section { TextField("Name", text: $name) }
                MailCriteriaFields(criteria: $criteria)
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save View") {
                    var view = editing ?? SavedInboxView(name: name, criteria: criteria)
                    view.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    view.criteria = criteria
                    store.saveInboxView(view)
                    store.selectSavedView(view)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !MailSearchQuery(source: criteria.query, defaultField: criteria.searchField).isValid)
            }.padding(24)
        }.frame(width: 500, height: 570)
            .mailPanelSurface()
            .onAppear {
                name = editing?.name ?? ""
                criteria = editing?.criteria ?? SavedInboxCriteria(query: store.searchText, account: store.selectedAccount,
                    unreadOnly: store.unreadOnly, attachmentsOnly: store.attachmentsOnly,
                    mailbox: store.searchScope == .allMailboxes ? nil : store.selectedMailbox)
                if editing == nil { criteria.searchField = store.searchField }
            }
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
