import SwiftUI

enum ReaderPanelAction: Equatable {
    case labels, snooze, followUp, privateNote, share, suggestions, details
    case calendar(MailCalendarEventDraft)

    func title(for message: MailMessage) -> String {
        switch self {
        case .labels: message.mailAccount.remote?.provider == "microsoft" ? "Outlook categories" : "Gmail labels"
        case .snooze: "Snooze conversation"
        case .followUp: "Follow-up reminder"
        case .privateNote: "Private note"
        case .share: "Share conversation"
        case .suggestions: "Suggested next steps"
        case .details: "Message details"
        case .calendar: "Review event"
        }
    }
}

struct ReaderPanelRequest: Identifiable {
    let id = UUID()
    let messageID: UUID
    let action: ReaderPanelAction
}

struct ReaderActionPanel: View {
    let request: ReaderPanelRequest
    let message: MailMessage
    let runtime: MailRuntime
    @Binding var noteDrafts: [UUID: String]
    let close: @MainActor @Sendable () -> Void
    @Environment(\.mailboxInset) private var inset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(request.action.title(for: message))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Close panel")
                .accessibilityLabel("Close \(request.action.title(for: message))")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(inset)
        .environment(\.dismissReaderPanel, ReaderPanelDismissAction(requestID: request.id) { close() })
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var panelContent: some View {
        switch request.action {
        case .labels:
            ScrollView { MessageLabelsView(runtime: runtime, message: message).padding(16) }
        case .snooze, .followUp:
            let snooze = request.action == .snooze
            ScrollView {
                MailScheduleEditor(purpose: snooze ? .snooze : .followUp,
                                   initialDate: snooze ? message.workflow.snoozedUntil : message.workflow.followUpAt,
                                   onlyIfNoReply: message.workflow.followUpOnlyIfNoReply,
                                   onCancel: close) { date, conditional in
                    if snooze { runtime.store.snoozeMessage(message.id, until: date) }
                    else { runtime.store.setFollowUp(message.id, at: date, onlyIfNoReply: conditional) }
                    close()
                }
                .padding(16)
            }
        case .privateNote:
            PrivateNoteEditor(store: runtime.store, message: message, draft: Binding(
                get: { noteDrafts[message.id] ?? message.workflow.privateNote },
                set: { noteDrafts[message.id] = $0 }
            ), onCancel: finishNote, onSave: finishNote)
            .padding(16)
        case .details:
            MessageEnvelopeDetailsView(message: message)
        case .suggestions:
            MailSuggestionsView(runtime: runtime, messages: runtime.store.conversationMessages(for: message))
                .id(message.id)
        case .share:
            ShareThreadView(runtime: runtime, message: message)
        case .calendar(let draft):
            ScrollView { CalendarEventDraftView(draft: draft) }
        }
    }

    private func finishNote() {
        noteDrafts.removeValue(forKey: message.id)
        close()
    }
}
