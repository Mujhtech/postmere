import SwiftUI
import WidgetKit

/// Writes what the widgets show into the shared App Group and reloads them only
/// when that content actually changed, to stay inside WidgetKit's reload budget.
@MainActor
enum MobileWidgetSync {
    private static var last: MailWidgetSnapshot?

    nonisolated struct Source: Equatable, Sendable {
        let revision: Int
        let sessionID: UUID?
        let accounts: Set<String>
        let signedIn: Bool
        let accountLabel: String
        let accentRGB: Int

        @MainActor init(runtime: MailRuntime) {
            revision = runtime.store.mailboxDataRevision
            sessionID = runtime.backend.realtimeGeneration
            accounts = runtime.store.searchableAccounts
            signedIn = sessionID != nil && !MailAccount.allCases.isEmpty
            accountLabel = MailAccount.scopeLabel(for: nil)
            accentRGB = UserDefaults.standard.object(forKey: PostmereAccent.preferenceKey) as? Int ?? PostmereAccent.defaultRGB
        }
    }

    /// Finish the snapshot before the app is suspended.
    static func publish(runtime: MailRuntime) {
        save(makeSnapshot(messages: runtime.store.messages, source: Source(runtime: runtime)))
    }

    static func refresh(runtime: MailRuntime, source: Source) async {
        guard !Task.isCancelled, source == Source(runtime: runtime) else { return }
        let snapshot = await prepare(messages: runtime.store.messages, source: source)
        guard !Task.isCancelled, source == Source(runtime: runtime) else { return }
        save(snapshot)
    }

    @concurrent private static func prepare(messages: [MailMessage], source: Source) async -> MailWidgetSnapshot {
        makeSnapshot(messages: messages, source: source)
    }

    private static func save(_ snapshot: MailWidgetSnapshot) {
        if last == nil { last = MailWidgetSnapshot.load() }
        guard !snapshot.sameContent(as: last) else { return }
        do {
            try snapshot.save()
            last = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // The widgets keep their previous snapshot; the next change tries again.
        }
    }

    private nonisolated static func makeSnapshot(messages: [MailMessage], source: Source) -> MailWidgetSnapshot {
        guard source.signedIn else { return .signedOut }
        let visible = messages.filter { source.accounts.contains($0.account) && !$0.isDeletedOnProvider && !$0.isDraft }
        let inbox = newestConversations(visible.filter { $0.mailbox == .inbox })
        let waiting = newestConversations(visible.filter(\.needsReply))
        return MailWidgetSnapshot(
            generatedAt: .now,
            isSignedIn: true,
            accountLabel: source.accountLabel,
            unread: inbox.count(where: \.isUnread),
            needsReply: waiting.count,
            inbox: inbox.prefix(8).map(widgetMessage),
            needsReplyList: waiting.prefix(6).map(widgetMessage),
            accentRGB: source.accentRGB)
    }

    /// The newest message of each conversation, newest first; a conversation is unread if any message is.
    private nonisolated static func newestConversations(_ messages: [MailMessage]) -> [MailMessage] {
        var byConversation: [UUID: MailMessage] = [:]
        var unread: Set<UUID> = []
        for message in messages {
            if message.isUnread { unread.insert(message.conversationID) }
            if let current = byConversation[message.conversationID], current.sentAt >= message.sentAt { continue }
            byConversation[message.conversationID] = message
        }
        return byConversation.values
            .map { message in
                var message = message
                if unread.contains(message.conversationID) { message.isUnread = true }
                return message
            }
            .sorted { $0.sentAt > $1.sentAt }
    }

    private nonisolated static func widgetMessage(_ message: MailMessage) -> MailWidgetSnapshot.Message {
        MailWidgetSnapshot.Message(
            id: message.id,
            sender: message.isOutgoing ? "To " + (message.toRecipients.first ?? "") : (message.sender.isEmpty ? message.senderEmail : message.sender),
            subject: message.displaySubject,
            preview: String(message.preview.prefix(140)),
            sentAt: message.sentAt,
            isUnread: message.isUnread,
            isStarred: message.isStarred,
            hasAttachments: !message.attachments.isEmpty)
    }
}

/// A `postmere://` link from a widget or control, waiting for the mailbox to open it.
@MainActor @Observable
final class MobileRouter {
    static let shared = MobileRouter()
    var pending: PostmereLink.Route?
    /// Settings opens straight to Assistants, from the assistant Live Activity.
    var opensAssistants = false
    /// The latest menu command or keyboard shortcut for the mailbox screen.
    var command: MobileCommandRequest?
}
