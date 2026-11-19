import Foundation

nonisolated struct MailSyncRepair {
    let messages: [MailMessage]
    let replacedIDs: [UUID: UUID]

    /// A row may link two older copies: one knows the provider ID and the other
    /// knows the backend ID. Resolve the whole group before choosing a survivor.
    static func collapse(_ messages: [MailMessage], preferring preferredIDs: Set<UUID> = []) -> Self {
        var firstByKey: [MailSyncIdentity: Int] = [:]
        var localSends: [UUID: Int] = [:]
        var parents = Array(messages.indices)
        var hasDuplicates = false

        func root(_ index: Int) -> Int {
            var i = index
            while parents[i] != i {
                parents[i] = parents[parents[i]]
                i = parents[i]
            }
            return i
        }

        func join(_ left: Int, _ right: Int) {
            let a = root(left), b = root(right)
            if a != b {
                parents[max(a, b)] = min(a, b)
                hasDuplicates = true
            }
        }

        for (index, message) in messages.enumerated() where message.account.hasPrefix("remote:") {
            if message.backendMessageID == nil, message.isOutgoing,
               message.mailbox == .outbox || message.mailbox == .sent, message.postmereSendID == message.id {
                localSends[message.id] = index
            }
            guard message.backendMessageID != nil || message.providerMessageID?.isEmpty == false else { continue }
            for key in MailSyncIdentity.keys(for: message) {
                if let first = firstByKey[key] {
                    join(first, index)
                } else {
                    firstByKey[key] = index
                }
            }
        }
        // A local send can reach the provider before its receipt acquires a provider ID.
        // Only link its generated Message-ID when it identifies one distinct provider delivery.
        if !localSends.isEmpty {
            var deliveries: [Int: Set<Int>] = [:]
            for (index, row) in messages.enumerated() where row.isOutgoing && row.backendMessageID != nil {
                guard let id = row.postmereSendID, let send = localSends[id], messages[send].account == row.account else { continue }
                if let knownID = messages[send].providerMessageID, !knownID.isEmpty,
                   let providerID = row.providerMessageID, !providerID.isEmpty, knownID != providerID { continue }
                deliveries[send, default: []].insert(root(index))
            }
            for (send, candidates) in deliveries where candidates.count == 1 {
                if let provider = candidates.first { join(send, provider) }
            }
        }
        guard hasDuplicates else { return Self(messages: messages, replacedIDs: [:]) }
        var copies: [Int: [Int]] = [:]
        for index in messages.indices where parents[index] != index {
            copies[root(index), default: []].append(index)
        }
        var repaired: [MailMessage] = []
        var replaced: [UUID: UUID] = [:]
        repaired.reserveCapacity(messages.count)
        for index in messages.indices where parents[index] == index {
            guard let otherIndices = copies[index] else { repaired.append(messages[index]); continue }
            let group = ([index] + otherIndices).map { messages[$0] }
            let row = mergeCopies(group, preferring: preferredIDs)
            for copy in group where copy.id != row.id { replaced[copy.id] = row.id }
            repaired.append(row)
        }
        return Self(messages: repaired, replacedIDs: replaced)
    }

    /// Receives a nonempty group already linked by the sync identity index.
    static func mergeCopies(_ group: [MailMessage], preferring preferredIDs: Set<UUID>) -> MailMessage {
        // Outgoing jobs refer to their original UUID as a delivery idempotency key.
        let owner = group.first { $0.mailbox == .outbox }
            ?? group.first { $0.isOutgoing && $0.postmereSendID == $0.id }
            ?? group.first { preferredIDs.contains($0.id) }
            ?? group[0]
        // Preserve the queued payload verbatim. Otherwise prefer a synced, live
        // representation over a tombstone or a local sent receipt.
        var row = owner.mailbox == .outbox || owner.isDraft ? owner :
            (group.last { !$0.isDeletedOnProvider && $0.backendMessageID != nil }
             ?? group.last { !$0.isDeletedOnProvider } ?? owner)
        row.id = owner.id
        row.conversationID = owner.conversationID
        row.workflow = owner.workflow
        var notes: [String] = []
        for copy in group {
            row.backendMessageID = row.backendMessageID ?? copy.backendMessageID
            if row.providerMessageID?.isEmpty != false { row.providerMessageID = copy.providerMessageID }
            row.backendOutboxID = row.backendOutboxID ?? copy.backendOutboxID
            row.trackOpens = row.trackOpens ?? copy.trackOpens
            row.trackLinks = row.trackLinks ?? copy.trackLinks
            row.envelopeDetails = row.envelopeDetails ?? copy.envelopeDetails
            if !copy.workflow.privateNote.isEmpty, !notes.contains(copy.workflow.privateNote) {
                notes.append(copy.workflow.privateNote)
            }
            if row.mailbox != .outbox, !row.isDraft {
                row.bodyHTML = row.bodyHTML ?? copy.bodyHTML
                row.bodyRTF = row.bodyRTF ?? copy.bodyRTF
                if row.paragraphs.isEmpty { row.paragraphs = copy.paragraphs }
                if copy.workflow.screeningState == .blocked { row.workflow.screeningState = .blocked }
                if let decision = copy.workflow.replyDecisionAt,
                   decision > (row.workflow.replyDecisionAt ?? .distantPast) {
                    row.workflow.replyDecisionAt = decision
                    row.workflow.needsReply = copy.workflow.needsReply
                } else if row.workflow.replyDecisionAt == nil {
                    row.workflow.needsReply = row.workflow.needsReply || copy.workflow.needsReply
                }
                row.workflow.snoozedUntil = row.workflow.snoozedUntil ?? copy.workflow.snoozedUntil
                if row.workflow.followUpAt == nil, copy.workflow.followUpAt != nil {
                    row.workflow.followUpAt = copy.workflow.followUpAt
                    row.workflow.followUpOnlyIfNoReply = copy.workflow.followUpOnlyIfNoReply
                    row.workflow.followUpReferenceDate = copy.workflow.followUpReferenceDate
                }
                row.retainDownloads(from: copy)
            }
        }
        row.workflow.privateNote = notes.joined(separator: "\n\n")
        return row
    }
}
