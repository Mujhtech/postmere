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
    @State private var date = Date.now.addingTimeInterval(3600)
    @State private var onlyIfNoReply = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(purpose.title).font(PostmereTheme.sheetTitle)
            HStack {
                Button("In one hour") { date = .now.addingTimeInterval(3600) }
                Button("Tomorrow") { date = tomorrow }
                Button("Next week") { date = Calendar.current.date(byAdding: .day, value: 6, to: tomorrow) ?? tomorrow }
            }.controlSize(.small)
            DatePicker("Date and time", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
            if purpose == .followUp || purpose == .composeFollowUp {
                Toggle("Only if nobody replies", isOn: $onlyIfNoReply)
            }
            if purpose == .sendLater {
                Text("Postmere must be open and your Mac awake to send. If it’s closed, delivery resumes when you open it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") { onSave(date, onlyIfNoReply); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(date <= .now)
            }
        }.padding(24).frame(width: 430)
    }

    private var tomorrow: Date {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: next) ?? next
    }
}

struct PrivateNoteSheet: View {
    @Bindable var store: MailStore
    let message: MailMessage
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Private note").font(PostmereTheme.sheetTitle)
            Text(message.subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            TextEditor(text: $note).font(.system(size: 13)).scrollIndicators(.never)
                .scrollContentBackground(.hidden)
                .frame(height: 180).accessibilityLabel("Private note")
                .padding(8)
                .background(PostmereTheme.subtleFill, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
                .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
            Text("Only stored on this Mac. Never included in an email.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.setPrivateNote(note, for: message.id); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460).onAppear { note = message.workflow.privateNote }
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
            }.formStyle(.grouped).scrollIndicators(.never)
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
                     : "Delivery resumes while Postmere is open.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if item.status == .failed && item.serverState != "uncertain" { Button("Retry Send") { store.retrySend(item.id) } }
                if item.status != .delivering && item.serverState != "uncertain" { Button("Cancel Send & Edit") { store.cancelQueuedSend(item.id) } }
            }.controlSize(.small)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(PostmereTheme.subtleFill, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
    }
}
