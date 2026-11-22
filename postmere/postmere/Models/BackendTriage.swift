import Foundation

/// What Postmere suggests doing with one message, and why. Only a suggestion:
/// Triage highlights it and the person decides.
nonisolated struct TriageSuggestion: Decodable, Equatable, Sendable {
    enum Action: String, Decodable, Sendable {
        case reply, needsReply = "needs_reply", archive, snooze, unsubscribe
        /// Worth reading, nothing to do yet.
        case keep = "none"
    }
    enum Priority: String, Decodable, Sendable {
        case needsYou = "needs_you", people, fyi, bulk
        /// Lower comes first in Triage.
        var rank: Int {
            switch self {
            case .needsYou: 0
            case .people: 1
            case .fyi: 2
            case .bulk: 3
            }
        }
        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .people: "People"
            case .fyi: "FYI"
            case .bulk: "Bulk"
            }
        }
    }
    enum Source: String, Decodable, Sendable { case history, rules, ai }

    let messageId: UUID
    let action: Action
    let priority: Priority
    let reason: String
    let deadline: String?
    let snoozeUntil: String?
    let source: Source

    static func day(_ text: String?) -> Date? {
        guard let text else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    var deadlineDate: Date? { Self.day(deadline) }
    /// 9 AM on the suggested day.
    var snoozeDate: Date? {
        Self.day(snoozeUntil).flatMap { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
    }
}

nonisolated struct TriageSuggestionRequest: Encodable, Sendable {
    let messageIds: [UUID]
    let today: String
}

nonisolated struct TriageSuggestionList: Decodable, Sendable {
    let suggestions: [Lossy<TriageSuggestion>]
}

nonisolated struct TriageFeedback: Encodable, Sendable {
    let messageId: UUID
    let action: String
}
