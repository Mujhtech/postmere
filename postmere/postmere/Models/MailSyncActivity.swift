import Foundation

nonisolated enum MailSyncActivity: Equatable, Sendable {
    case idle
    case syncing
    case loadingCache(loaded: Int)
    case importing(cached: Int?)
    case waiting(retryAt: Date)

    var isActive: Bool { self != .idle }

    var title: String {
        switch self {
        case .idle: ""
        case .syncing: "Syncing"
        case .loadingCache: "Loading"
        case .importing: "Importing"
        case .waiting: "Paused"
        }
    }

    var detail: String? {
        switch self {
        case .idle, .syncing: nil
        case .loadingCache(let loaded): loaded > 0 ? "\(loaded.formatted()) loaded" : nil
        case .importing(let cached): cached.map { "\($0.formatted()) imported" }
        case .waiting(let retryAt): "Until \(retryAt.formatted(date: .omitted, time: .shortened))"
        }
    }

    var explanation: String {
        switch self {
        case .idle: return ""
        case .syncing: return "Checking the mail provider for changes."
        case .loadingCache(let loaded):
            return loaded > 0
                ? "Loading saved mail on this Mac. \(Self.messages(loaded)) loaded."
                : "Loading saved mail on this Mac."
        case .importing(let cached):
            return cached.map { "Importing mail in the background. \(Self.messages($0)) imported." }
                ?? "Importing mail in the background."
        case .waiting(let retryAt):
            return "Mail sync is paused. The next attempt is scheduled for \(retryAt.formatted(date: .abbreviated, time: .shortened))."
        }
    }

    private static func messages(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count.formatted()) messages"
    }
}
