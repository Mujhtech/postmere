import ActivityKit
import Foundation

/// Mirrors the outgoing queue as Live Activities: one per message on its way out,
/// from the undo window through a scheduled send to delivered or failed.
@MainActor
enum MobileLiveActivities {
    private typealias SendActivity = Activity<MailSendActivityAttributes>
    private typealias State = MailSendActivityAttributes.ContentState

    /// Live Activities stay up at most eight hours; later scheduled sends don't get one.
    private static let longestWait: TimeInterval = 8 * 3600
    private static var tick: Task<Void, Never>?
    private static var isObserving = false

    /// Starts following the queue. Safe to call more than once.
    static func start(runtime: MailRuntime) {
        UndoSendIntent.handler = { [weak runtime] id in runtime?.store.undoSend(id) }
        guard !isObserving else { return }
        isObserving = true
        observe(runtime)
        sync(runtime: runtime)
    }

    private static func observe(_ runtime: MailRuntime) {
        withObservationTracking {
            _ = runtime.store.outgoingQueue
        } onChange: { [weak runtime] in
            Task { @MainActor in
                guard let runtime else { return }
                sync(runtime: runtime)
                observe(runtime)
            }
        }
    }

    static func sync(runtime: MailRuntime, now: Date = .now) {
        let store = runtime.store
        let running = SendActivity.activities
        var following: Set<UUID> = []
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled

        for item in store.outgoingQueue {
            guard let message = store.messages.first(where: { $0.id == item.id }) else { continue }
            let state = state(for: item, now: now)
            if let activity = running.first(where: { $0.attributes.messageID == item.id }) {
                following.insert(item.id)
                guard activity.content.state != state else { continue }
                let content = ActivityContent(state: state, staleDate: staleDate(for: item, state: state))
                Task { await activity.update(content) }
            } else if enabled, state.phase != .failed, item.scheduledAt.timeIntervalSince(now) < longestWait {
                let attributes = MailSendActivityAttributes(messageID: item.id, recipient: recipient(message),
                                                            subject: message.displaySubject, accentRGB: accentRGB)
                let content = ActivityContent(state: state, staleDate: staleDate(for: item, state: state),
                                              relevanceScore: state.canUndo ? 100 : 50)
                if (try? SendActivity.request(attributes: attributes, content: content, pushType: nil)) != nil {
                    following.insert(item.id)
                }
            }
        }

        // Gone from the queue: sent, or taken back into Drafts.
        for activity in running where !following.contains(activity.attributes.messageID) {
            let message = store.messages.first { $0.id == activity.attributes.messageID }
            if message?.mailbox == .sent {
                var state = activity.content.state
                state.phase = .sent
                let content = ActivityContent(state: state, staleDate: nil)
                Task { await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(4))) }
            } else if activity.content.state.phase != .sent {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
        scheduleTick(runtime: runtime, now: now)
    }

    /// The undo window closing and a scheduled time arriving change the phase with
    /// no queue change, so wake for the next of those.
    private static func scheduleTick(runtime: MailRuntime, now: Date) {
        tick?.cancel()
        let boundaries = runtime.store.outgoingQueue
            .filter { $0.status == .pending }
            .flatMap { [$0.undoUntil, $0.scheduledAt] }
            .filter { $0 > now }
        guard let next = boundaries.min() else { tick = nil; return }
        tick = Task { [weak runtime] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.3))
            guard !Task.isCancelled, let runtime else { return }
            sync(runtime: runtime)
        }
    }

    private static func state(for item: OutgoingMailItem, now: Date) -> State {
        let phase: State.Phase
        switch item.status {
        case .failed: phase = .failed
        case .delivering: phase = .sending
        case .pending:
            if item.undoUntil > now {
                phase = item.scheduledAt.timeIntervalSince(item.undoUntil) > 60 ? .scheduled : .undo
            } else if item.scheduledAt > now {
                phase = .scheduled
            } else {
                phase = .sending
            }
        }
        let detail = phase == .failed ? "Open Postmere to retry" : nil
        return State(phase: phase, queuedAt: item.queuedAt, undoUntil: item.undoUntil, scheduledAt: item.scheduledAt, detail: detail)
    }

    /// After this the activity shows "Sending…" by itself, even if the app is asleep.
    private static func staleDate(for item: OutgoingMailItem, state: State) -> Date? {
        switch state.phase {
        case .undo: max(item.undoUntil, item.scheduledAt)
        case .scheduled: item.scheduledAt
        default: nil
        }
    }

    private static var accentRGB: Int {
        UserDefaults.standard.object(forKey: PostmereAccent.preferenceKey) as? Int ?? PostmereAccent.defaultRGB
    }

    /// "Ada Okafor", "ada@example.com", or "Ada Okafor and 2 others".
    private static func recipient(_ message: MailMessage) -> String {
        let all = message.toRecipients + message.ccRecipients
        guard let first = all.first else { return "No recipient" }
        var name = first
        if let open = first.firstIndex(of: "<") {
            let display = first[..<open].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
            if !display.isEmpty { name = display }
        }
        return all.count > 1 ? "\(name) and \(all.count - 1) other\(all.count == 2 ? "" : "s")" : name
    }
}
