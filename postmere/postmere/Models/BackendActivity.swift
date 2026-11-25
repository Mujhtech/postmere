import Foundation

/// Open and click tracking for a sent message.
nonisolated struct BackendActivityResponse: Decodable, Sendable {
    let items: [BackendActivity]
    let attributionNotice: String
}
nonisolated struct BackendActivity: Decodable, Sendable {
    let outboxId: UUID
    let opens: Int
    let clicks: Int
    let firstOpenAt: Date?
    let lastOpenAt: Date?
    let firstClickAt: Date?
    let lastClickAt: Date?
    let events: [BackendActivityEvent]
}
nonisolated struct BackendActivityEvent: Decodable, Identifiable, Sendable {
    let id: UUID
    let kind: String
    let occurredAt: Date
    let recipient: String?
    let device: String
    let isProxyOrBot: Bool
}
