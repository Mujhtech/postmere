import Foundation

/// Reply decisions belong to one conversation in one mailbox account. A sent
/// reply or a dismissal also covers older messages imported afterwards.
nonisolated enum MailReplyQueue {
    static func index(_ messages: inout [MailMessage], preservingLegacyFlags: Bool = false) {
        let migrationDate = Date.now
        for index in messages.indices {
            if preservingLegacyFlags && messages[index].workflow.needsReply && messages[index].workflow.replyDecisionAt == nil {
                messages[index].workflow.replyDecisionAt = migrationDate
            }
            messages[index].replyRequestCandidates = MailReplyIntent.candidates(in: messages[index])
            messages[index].replyRequestText = nil
        }
        reconcile(&messages)
    }

    private static func sentenceKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func reconcile(_ messages: inout [MailMessage], conversations: Set<UUID>? = nil) {
        struct Thread {
            var latestReply = Date.distantPast
            var dismissedThrough = Date.distantPast
            var firstSentAt: [String: Date] = [:]
            var latestRequest: Int?
        }
        var threads: [String: Thread] = [:]
        let indices = messages.indices.filter { conversations?.contains(messages[$0].conversationID) ?? true }
        for index in indices {
            let message = messages[index]
            guard message.mailbox != .junk else { continue }
            let key = message.searchConversationKey
            if message.isFromAccountOwner && !message.isDraft && message.mailbox != .outbox && !message.isDeletedOnProvider {
                threads[key, default: Thread()].latestReply = max(threads[key]?.latestReply ?? .distantPast, message.sentAt)
                if message.replyRequestCandidates == nil && conversations != nil {
                    // A locally queued message may have just transitioned to Sent.
                    messages[index].replyRequestCandidates = MailReplyIntent.candidates(in: message)
                }
                for question in messages[index].replyRequestCandidates ?? [] {
                    let keyText = sentenceKey(question)
                    let first = threads[key]?.firstSentAt[keyText] ?? .distantFuture
                    threads[key, default: Thread()].firstSentAt[keyText] = min(first, message.sentAt)
                }
            }
            if !message.workflow.needsReply, let decision = message.workflow.replyDecisionAt {
                threads[key, default: Thread()].dismissedThrough = max(threads[key]?.dismissedThrough ?? .distantPast, decision)
            }
        }
        for index in indices {
            let message = messages[index]
            let key = message.searchConversationKey
            guard !message.isFromAccountOwner, message.mailbox == .inbox, !message.isDeletedOnProvider else {
                if message.replyRequestText != nil { messages[index].replyRequestText = nil }
                continue
            }
            // Older snapshots can still be visible during the background index upgrade.
            let candidates = message.replyRequestCandidates ?? message.replyRequestText.map { [$0] } ?? []
            let authored = threads[key]?.firstSentAt
            let request = candidates.first { candidate in
                guard let authored, !authored.isEmpty, let sent = authored[sentenceKey(candidate)] else { return true }
                return sent > message.sentAt
            }
            if message.replyRequestText != request { messages[index].replyRequestText = request }
            if request != nil {
                let previous = threads[key]?.latestRequest
                if previous.map({ messages[$0].sentAt < message.sentAt }) ?? true {
                    threads[key, default: Thread()].latestRequest = index
                }
            }
        }
        for index in indices {
            let message = messages[index]
            let thread = threads[message.searchConversationKey]
            let reply = thread?.latestReply ?? .distantPast
            if message.workflow.needsReply && reply >= (message.workflow.replyDecisionAt ?? message.sentAt) {
                messages[index].workflow.needsReply = false
            }
            let pending = thread?.latestRequest == index && message.sentAt > max(reply, thread?.dismissedThrough ?? .distantPast)
            if (message.automaticReplyPending == true) != pending { messages[index].automaticReplyPending = pending ? true : nil }
        }
    }

    @concurrent static func savedCandidates(in messages: [MailMessage]) async -> [UUID: (MailMessage, [String]?)] {
        var result: [UUID: (MailMessage, [String]?)] = [:]
        for message in messages {
            if Task.isCancelled { break }
            result[message.id] = (message, MailReplyIntent.candidates(in: message))
        }
        return result
    }

    @concurrent static func corrections(in messages: [MailMessage], using candidates: [UUID: (MailMessage, [String]?)],
                                        preservingLegacyFlags: Bool) async -> [(Int, MailMessage)] {
        var indexed = messages
        let now = Date.now
        for index in messages.indices {
            if Task.isCancelled { return [] }
            let current = messages[index]
            if let (original, found) = candidates[current.id], original == current {
                indexed[index].replyRequestCandidates = found
            } else {
                indexed[index].replyRequestCandidates = MailReplyIntent.candidates(in: current)
            }
            indexed[index].replyRequestText = nil
            if preservingLegacyFlags && current.workflow.needsReply && current.workflow.replyDecisionAt == nil {
                indexed[index].workflow.replyDecisionAt = now
            }
        }
        reconcile(&indexed)
        return messages.indices.compactMap { indexed[$0] == messages[$0] ? nil : ($0, indexed[$0]) }
    }
}

extension MailStore {
    func indexSavedReplyRequests() async {
        let candidates = await MailReplyQueue.savedCandidates(in: messages)
        while !Task.isCancelled && replyIndexVersion < MailStateSnapshot.currentReplyIndexVersion {
            let revision = mailboxDataRevision
            let changes = await MailReplyQueue.corrections(in: messages, using: candidates, preservingLegacyFlags: replyIndexVersion == 0)
            guard !Task.isCancelled, replyIndexVersion < MailStateSnapshot.currentReplyIndexVersion else { return }
            // Sync and local decisions can progress while analysis runs. Reconcile
            // the current snapshot, reusing candidate extraction for unchanged mail.
            guard revision == mailboxDataRevision else { continue }
            replyIndexVersion = MailStateSnapshot.currentReplyIndexVersion
            if !changes.isEmpty {
                var updated = messages
                for (index, correction) in changes {
                    updated[index].replyRequestCandidates = correction.replyRequestCandidates
                    updated[index].replyRequestText = correction.replyRequestText
                    updated[index].automaticReplyPending = correction.automaticReplyPending
                    updated[index].workflow.replyDecisionAt = correction.workflow.replyDecisionAt
                    updated[index].workflow.needsReply = correction.workflow.needsReply
                }
                let previous = suppressRemoteMutations
                suppressRemoteMutations = true
                messages = updated
                suppressRemoteMutations = previous
            }
            schedulePersistence()
        }
    }
}
