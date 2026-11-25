import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Handoff of the open conversation between Mac, iPhone and iPad, and Spotlight
/// search over recent mail on this device.
enum MailContinuity {
    /// Also listed under NSUserActivityTypes in both apps' Info.plist.
    static let messageActivityType = "mujhtech.postmere.message"

    /// Describes the open conversation so another device signed in to the same
    /// workspace can open it. Local message IDs differ per device, so it carries
    /// the server's message ID and the account it belongs to.
    static func configure(_ activity: NSUserActivity, for message: MailMessage) {
        activity.title = message.displaySubject.isEmpty ? "Message from \(message.sender)" : message.displaySubject
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        var info: [String: Any] = ["account": message.account]
        if let backendID = message.backendMessageID { info["backendMessageID"] = backendID.uuidString }
        activity.userInfo = info
        activity.requiredUserInfoKeys = Set(info.keys)
    }

    /// The server message an activity from another device points at.
    static func handoffReference(_ activity: NSUserActivity) -> (backendID: UUID, account: String)? {
        guard activity.activityType == messageActivityType,
              let account = activity.userInfo?["account"] as? String, account.hasPrefix("remote:"),
              let id = (activity.userInfo?["backendMessageID"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return (id, account)
    }

    /// The local message a Spotlight result points at.
    static func spotlightMessageID(_ activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        return (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// Keeps Spotlight's copy of recent mail in step with this device: the newest
/// conversations, rebuilt a little after the mailbox settles, removed on sign-out.
/// Only subjects, senders and a short preview are indexed, and only on this device.
@MainActor
final class MailSpotlightIndexer {
    static let preferenceKey = "spotlightIndexesMail"
    private static let limit = 1_000
    private let index = CSSearchableIndex(name: "postmere-mail")
    private var indexedFingerprint: Int?
    private var pending: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }

    /// Call when mail changes; work is debounced and done off the main thread.
    func update(messages: [MailMessage], signedIn: Bool) {
        guard signedIn, Self.isEnabled else {
            if indexedFingerprint != nil || pending != nil { clear() }
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            let (fingerprint, items) = await Self.items(from: messages)
            guard !Task.isCancelled, fingerprint != self.indexedFingerprint else { return }
            do {
                try await self.index.deleteAllSearchableItems()
                try await self.index.indexSearchableItems(items)
                self.indexedFingerprint = fingerprint
            } catch {
                self.indexedFingerprint = nil
            }
        }
    }

    func clear() {
        pending?.cancel()
        pending = nil
        indexedFingerprint = nil
        let index = index
        Task { try? await index.deleteAllSearchableItems() }
    }

    @concurrent private static func items(from messages: [MailMessage]) async -> (Int, [CSSearchableItem]) {
        var newest: [UUID: MailMessage] = [:]
        for message in messages where !message.isDraft && !message.isDeletedOnProvider
            && message.mailbox != .trash && message.mailbox != .junk && message.mailbox != .outbox {
            if let current = newest[message.conversationID], current.sentAt >= message.sentAt { continue }
            newest[message.conversationID] = message
        }
        let chosen = newest.values.sorted { $0.sentAt > $1.sentAt }.prefix(limit)
        var hasher = Hasher()
        for message in chosen {
            hasher.combine(message.id)
            hasher.combine(message.subject)
        }
        let items = chosen.map { message -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
            attributes.title = message.displaySubject.isEmpty ? "No subject" : message.displaySubject
            attributes.contentDescription = "\(message.sender) — \(message.displayPreview)"
            attributes.authorNames = [message.sender]
            attributes.authorEmailAddresses = [message.senderEmail]
            attributes.emailAddresses = [message.senderEmail]
            attributes.contentCreationDate = message.sentAt
            attributes.keywords = [message.sender, message.senderEmail]
            let item = CSSearchableItem(uniqueIdentifier: message.id.uuidString,
                                        domainIdentifier: message.account, attributeSet: attributes)
            item.expirationDate = .distantFuture
            return item
        }
        return (hasher.finalize(), Array(items))
    }
}
