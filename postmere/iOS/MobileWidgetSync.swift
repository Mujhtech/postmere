import SwiftUI
import WidgetKit

/// Writes what the widgets show into the shared App Group and reloads them only
/// when that content actually changed, to stay inside WidgetKit's reload budget.
@MainActor
enum MobileWidgetSync {
    private static var last: MailWidgetSnapshot?

    static func publish(runtime: MailRuntime) {
        let snapshot = makeSnapshot(runtime: runtime)
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

    private static func makeSnapshot(runtime: MailRuntime) -> MailWidgetSnapshot {
        let store = runtime.store
        let signedIn = runtime.backend.canAccessWorkspace && !MailAccount.allCases.isEmpty
        guard signedIn else { return .signedOut }
        let visible = store.messages.filter { store.isAccountVisible($0) && !$0.isDeletedOnProvider && !$0.isDraft }
        let inbox = newestConversations(visible.filter { $0.mailbox == .inbox })
        let waiting = newestConversations(visible.filter(\.needsReply))
        let rgb = UserDefaults.standard.object(forKey: PostmereAccent.preferenceKey) as? Int ?? PostmereAccent.defaultRGB
        return MailWidgetSnapshot(
            generatedAt: .now,
            isSignedIn: true,
            accountLabel: MailAccount.scopeLabel(for: nil),
            unread: inbox.count(where: \.isUnread),
            needsReply: waiting.count,
            inbox: inbox.prefix(8).map(widgetMessage),
            needsReplyList: waiting.prefix(6).map(widgetMessage),
            accentRGB: rgb)
    }

    /// The newest message of each conversation, newest first; a conversation is unread if any message is.
    private static func newestConversations(_ messages: [MailMessage]) -> [MailMessage] {
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

    private static func widgetMessage(_ message: MailMessage) -> MailWidgetSnapshot.Message {
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
}
