#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// A message on its way out: the undo window, a scheduled send, delivery, then sent.
/// Shown on the Lock Screen and in the Dynamic Island while the app is in the background.
nonisolated struct MailSendActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            /// Can still be taken back, until `undoUntil`.
            case undo
            /// Waiting for `scheduledAt` (Send Later).
            case scheduled
            case sending
            case sent
            case failed
        }

        var phase: Phase
        /// When Send was tapped, so the undo bar can show how much time is left.
        var queuedAt: Date
        var undoUntil: Date
        var scheduledAt: Date
        /// Why a send failed, in a few words.
        var detail: String?

        var canUndo: Bool { phase == .undo || phase == .scheduled }
    }

    let messageID: UUID
    /// "Ada Okafor", or "Ada and 2 others".
    let recipient: String
    let subject: String
    let accentRGB: Int
}

/// The Undo button on the Live Activity. It runs in the app, which cancels the send.
nonisolated struct UndoSendIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Undo Send"
    static let description = IntentDescription("Takes back a message before it is sent.")
    static let isDiscoverable = false

    @Parameter(title: "Message")
    var messageID: String

    init() {}
    init(messageID: UUID) { self.messageID = messageID.uuidString }

    /// Set by the app at launch. The widget extension leaves it empty.
    @MainActor static var handler: ((UUID) -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: messageID) { Self.handler?(id) }
        return .result()
    }
}
#endif
