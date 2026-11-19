import Foundation

enum InboxSplitOverlapPolicy: String, Codable, CaseIterable {
    case firstMatch, allMatches

    var title: String { self == .firstMatch ? "First matching tab" : "Every matching tab" }
    var explanation: String {
        self == .firstMatch
            ? "A conversation appears in the first visible tab whose rules it matches. Reorder tabs to change priority."
            : "A conversation appears in every visible tab whose rules it matches. All Inbox still shows everything once."
    }
}

nonisolated struct InboxSplit: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var criteria: SavedInboxCriteria
    var isHidden = false

    static var defaults: [InboxSplit] {
        [
            InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0001")!, name: "Important",
                       criteria: SavedInboxCriteria(query: "is:vip OR is:starred OR is:needsreply")),
            InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0002")!, name: "People",
                       criteria: SavedInboxCriteria(query: "is:incoming -has:unsubscribe -category:promotions -category:forums -category:updates -category:social -from:noreply -from:no-reply -from:notifications")),
            InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0003")!, name: "Newsletters",
                       criteria: SavedInboxCriteria(query: "has:unsubscribe OR category:promotions OR category:forums")),
            InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0004")!, name: "Notifications",
                       criteria: SavedInboxCriteria(query: "category:updates OR category:social OR from:noreply OR from:no-reply OR from:notifications"))
        ]
    }
}

nonisolated struct VIPContact: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case person, domain }
    var id = UUID()
    var value: String
    var kind: Kind
    var account: String?
    var providerAccountEmail: String?
    var includeSubdomains = true

    var normalizedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isValid: Bool {
        let value = normalizedValue
        if kind == .person {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && !parts[0].contains(where: { $0.isWhitespace })
                && parts[0].rangeOfCharacter(from: CharacterSet(charactersIn: "<>(),;:\\\"")) == nil
                && Self.isValidDomain(String(parts[1]))
        }
        return Self.isValidDomain(value)
    }

    func matches(_ message: MailMessage) -> Bool {
        guard isValid, !message.isOutgoing,
              account == nil || account == message.account,
              providerAccountEmail == nil || providerAccountEmail?.lowercased() == message.providerAccountEmail?.lowercased() else { return false }
        let sender = message.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kind == .person { return sender == normalizedValue }
        guard let domain = sender.split(separator: "@").last.map(String.init), sender.contains("@") else { return false }
        return domain == normalizedValue || (includeSubdomains && domain.hasSuffix(".\(normalizedValue)"))
    }

    private static func isValidDomain(_ value: String) -> Bool {
        guard value.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-"
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
