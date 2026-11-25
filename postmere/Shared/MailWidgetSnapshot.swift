import Foundation

/// What the widgets show, written by the app into the shared App Group container
/// whenever it changes. Widgets never touch the network or the mail database.
nonisolated struct MailWidgetSnapshot: Codable, Equatable, Sendable {
    nonisolated struct Message: Codable, Equatable, Hashable, Identifiable, Sendable {
        let id: UUID
        let sender: String
        let subject: String
        let preview: String
        let sentAt: Date
        let isUnread: Bool
        let isStarred: Bool
        let hasAttachments: Bool

        var initials: String {
            let words = sender.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
            return letters.isEmpty ? "?" : String(letters).uppercased()
        }
    }

    var generatedAt: Date
    var isSignedIn: Bool
    var accountLabel: String
    /// Unread conversations in the inbox.
    var unread: Int
    /// Conversations marked as needing a reply.
    var needsReply: Int
    var inbox: [Message]
    var needsReplyList: [Message]
    var accentRGB: Int

    /// Content only, so a refresh that changes nothing visible doesn't reload widgets.
    func sameContent(as other: Self?) -> Bool {
        guard let other else { return false }
        var mine = self, theirs = other
        mine.generatedAt = .distantPast
        theirs.generatedAt = .distantPast
        return mine == theirs
    }

    static let appGroup = "group.mujhtech.postmere"
    private static let fileName = "widget-snapshot.json"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func load() -> Self? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static let signedOut = MailWidgetSnapshot(generatedAt: .now, isSignedIn: false, accountLabel: "", unread: 0,
                                              needsReply: 0, inbox: [], needsReplyList: [], accentRGB: 0x498775)

    /// Sample mail for the widget gallery and placeholders.
    static let sample: MailWidgetSnapshot = {
        let now = Date.now
        func message(_ sender: String, _ subject: String, _ preview: String, minutes: Double, unread: Bool) -> Message {
            Message(id: UUID(), sender: sender, subject: subject, preview: preview,
                    sentAt: now.addingTimeInterval(-minutes * 60), isUnread: unread, isStarred: false, hasAttachments: false)
        }
        let inbox = [
            message("Ada Okafor", "Design review moved to Thursday", "Could we push the review to Thursday at 2pm?", minutes: 4, unread: true),
            message("Stripe", "Your November invoice", "Your invoice for November is ready to view.", minutes: 38, unread: true),
            message("Sam Lee", "Quick question about the launch", "Do we have final copy for the landing page?", minutes: 95, unread: true),
            message("GitHub", "[postmere] New pull request", "feat: widgets for the home screen", minutes: 180, unread: false),
            message("Maya Chen", "Dinner on Friday?", "There’s a new place near the office I want to try.", minutes: 300, unread: false),
            message("Linear", "3 issues assigned to you", "MAIL-214, MAIL-215 and MAIL-219 need you.", minutes: 420, unread: false),
            message("Figma", "Comments on Onboarding v4", "Two new comments on the welcome screen.", minutes: 600, unread: false),
            message("Notion", "Weekly digest", "Here’s what changed in your workspace.", minutes: 900, unread: false),
        ]
        return MailWidgetSnapshot(generatedAt: now, isSignedIn: true, accountLabel: "All accounts", unread: 12,
                                  needsReply: 3, inbox: inbox, needsReplyList: Array(inbox.prefix(3)), accentRGB: 0x498775)
    }()
}

/// `postmere://` routes the widgets, controls and notifications open.
nonisolated enum PostmereLink {
    static let scheme = "postmere"

    enum Route: Equatable, Sendable {
        case inbox, needsReply, compose, ask, triage, assistants
        case message(UUID)
    }

    static func url(_ route: Route) -> URL {
        let path = switch route {
        case .inbox: "inbox"
        case .needsReply: "needs-reply"
        case .compose: "compose"
        case .ask: "ask"
        case .triage: "triage"
        case .assistants: "assistants"
        case .message(let id): "message/\(id.uuidString)"
        }
        return URL(string: "\(scheme)://\(path)")!
    }

    static func route(for url: URL) -> Route? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        switch parts.first {
        case "inbox": return .inbox
        case "needs-reply": return .needsReply
        case "compose": return .compose
        case "ask": return .ask
        case "triage": return .triage
        case "assistants": return .assistants
        case "message": return parts.dropFirst().first.flatMap(UUID.init(uuidString:)).map(Route.message)
        default: return nil
        }
    }
}
