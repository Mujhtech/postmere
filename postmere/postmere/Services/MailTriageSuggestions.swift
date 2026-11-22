import Foundation
import Observation

/// Triage suggestions for the inbox, fetched in the background as mail arrives
/// and kept for the session, and the decisions made in Triage, sent back so
/// Postmere learns each person's habits by sender.
@MainActor @Observable
final class MailTriageSuggestions {
    /// By local message ID.
    private(set) var byMessage: [UUID: TriageSuggestion] = [:]
    /// Receives each batch's priorities, so the Needs you tab and search follow.
    @ObservationIgnored var onPriorities: (([UUID: String]) -> Void)?
    @ObservationIgnored private var generation = UUID()

    func suggestion(for message: MailMessage) -> TriageSuggestion? { byMessage[message.id] }

    @ObservationIgnored private var inFlight = false
    /// When each unanswered message may be asked about again.
    @ObservationIgnored private var retryAt: [UUID: Date] = [:]
    /// After an error or rate limit, nothing is asked until then.
    @ObservationIgnored private var pausedUntil = Date.distantPast

    /// Asks the server about up to 50 messages it has not answered yet, one
    /// request at a time. The server answers a limited number with AI per
    /// request; the rest wait a while before being asked again, so mail
    /// changes never turn into a stream of requests.
    func prefetch(_ messages: [MailMessage], session: BackendSession, now: Date = .now) async {
        guard session.canAccessWorkspace, !inFlight, now >= pausedUntil else { return }
        var local: [UUID: UUID] = [:]
        for message in messages where byMessage[message.id] == nil && !message.isOutgoing && !message.isDraft {
            guard let backend = message.backendMessageID, retryAt[backend].map({ now >= $0 }) ?? true else { continue }
            local[backend] = message.id
            if local.count == 50 { break }
        }
        guard !local.isEmpty else { return }
        let started = generation
        let chunk = Array(local.keys)
        inFlight = true
        defer { if started == generation { inFlight = false } }
        let today = now.formatted(.iso8601.year().month().day())
        do {
            let list: TriageSuggestionList = try await session.request(
                "POST", "/v1/decisions/triage", body: TriageSuggestionRequest(messageIds: chunk, today: today))
            guard started == generation else { return }
            var answered: Set<UUID> = []
            var priorities: [UUID: String] = [:]
            for suggestion in list.suggestions.compactMap(\.value) {
                answered.insert(suggestion.messageId)
                retryAt[suggestion.messageId] = nil
                if let id = local[suggestion.messageId] {
                    byMessage[id] = suggestion
                    priorities[id] = suggestion.priority.rawValue
                }
            }
            if !priorities.isEmpty { onPriorities?(priorities) }
            for id in chunk where !answered.contains(id) { retryAt[id] = now.addingTimeInterval(90) }
        } catch {
            guard started == generation else { return }
            pausedUntil = now.addingTimeInterval(120)
        }
    }

    /// Orders a Triage queue: what needs you first, bulk last; ties keep their order.
    func ordered(_ ids: [UUID]) -> [UUID] {
        ids.enumerated().sorted { lhs, rhs in
            let left = byMessage[lhs.element]?.priority.rank ?? 1
            let right = byMessage[rhs.element]?.priority.rank ?? 1
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Bulk mail suggested for archiving, offered as one decision when there
    /// are at least three; otherwise none.
    func batch(in ids: [UUID]) -> [UUID] {
        let bulk = ids.filter { id in
            guard let suggestion = byMessage[id] else { return false }
            return suggestion.priority == .bulk && (suggestion.action == .archive || suggestion.action == .unsubscribe)
        }
        return bulk.count >= 3 ? bulk : []
    }

    /// Tells the server what the person chose, by sender. Undo is not sent;
    /// one stray choice does not outweigh a habit.
    func record(_ decision: TriageSession.Decision, for message: MailMessage, session: BackendSession) {
        guard let backend = message.backendMessageID, session.canAccessWorkspace else { return }
        let action = switch decision {
        // Unsubscribing teaches the same habit as archiving.
        case .archive, .unsubscribe: "archive"
        case .trash: "trash"
        case .snooze: "snooze"
        case .reply: "reply"
        case .needsReply: "needs_reply"
        case .skip: "skip"
        }
        Task {
            let _: BackendEmpty? = try? await session.request("POST", "/v1/decisions/triage/feedback",
                                                               body: TriageFeedback(messageId: backend, action: action))
        }
    }

    func reset() {
        generation = UUID()
        byMessage = [:]
        retryAt = [:]
        inFlight = false
        pausedUntil = .distantPast
    }
}
