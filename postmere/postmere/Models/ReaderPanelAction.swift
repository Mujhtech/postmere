import Foundation

enum ReaderPanelAction: Equatable {
    case labels, snooze, followUp, privateNote, share, suggestions, details, plugins
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
        case .plugins: "Plugins"
        case .calendar: "Review event"
        }
    }
}

struct ReaderPanelRequest: Identifiable {
    let id = UUID()
    let messageID: UUID
    let action: ReaderPanelAction
}
