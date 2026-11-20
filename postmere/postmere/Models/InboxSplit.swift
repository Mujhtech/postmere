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

    static let peopleQuery = "is:incoming -has:unsubscribe -category:promotions -category:forums -category:updates -category:social -from:noreply -from:no-reply -from:notifications"

    static let defaultsVersion = 1
    private static let stockPeople = InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0002")!, name: "People",
                                              criteria: SavedInboxCriteria(query: peopleQuery + " -is:subscription -is:purchase"))
    private static let subscriptions = InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0003")!, name: "Subscriptions",
                                                 criteria: SavedInboxCriteria(query: "is:subscription"))
    private static let purchases = InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0005")!, name: "Purchases",
                                             criteria: SavedInboxCriteria(query: "is:purchase"))
    private static let notifications = InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0004")!, name: "Notifications",
                                                 criteria: SavedInboxCriteria(query: "category:updates OR category:social OR from:noreply OR from:no-reply OR from:notifications"))

    static let defaults: [InboxSplit] = [
        InboxSplit(id: UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0001")!, name: "Important",
                   criteria: SavedInboxCriteria(query: "is:vip OR is:starred OR is:needsreply")),
        stockPeople, purchases, subscriptions, notifications
    ]

    static func upgradingLegacyTabs(_ saved: [InboxSplit]) -> [InboxSplit] {
        var tabs = saved
        if let index = tabs.firstIndex(where: { $0.id == stockPeople.id && $0.name == stockPeople.name
            && $0.criteria == SavedInboxCriteria(query: peopleQuery) }) {
            tabs[index].criteria = stockPeople.criteria
        }

        let legacyIndex = tabs.firstIndex { $0.id == subscriptions.id }
        let legacyCriteria = SavedInboxCriteria(query: "has:unsubscribe OR category:promotions OR category:forums")
        if let index = legacyIndex, tabs[index].name == "Newsletters", tabs[index].criteria == legacyCriteria {
            // Identity, selection, position and visibility belong to the user.
            if !tabs.contains(where: { $0.id != subscriptions.id && $0.name.caseInsensitiveCompare(subscriptions.name) == .orderedSame }) {
                tabs[index].name = subscriptions.name
            }
            tabs[index].criteria = subscriptions.criteria
        } else if !tabs.contains(where: { $0.name.caseInsensitiveCompare(subscriptions.name) == .orderedSame }) {
            var added = subscriptions
            if legacyIndex != nil {
                // The old ID belongs to a customized tab. Give the new definition its own identity.
                added.id = UUID(uuidString: "26FDFE19-6DC0-48FC-B849-87939F0A0006")!
            } else {
                // Keep a previously removed mailing-list tab out of the tab bar.
                added.isHidden = true
            }
            if !tabs.contains(where: { $0.id == added.id }) {
                tabs.insert(added, at: tabs.firstIndex { $0.id == notifications.id } ?? tabs.endIndex)
            }
        }

        if !tabs.contains(where: { $0.id == purchases.id || $0.name.caseInsensitiveCompare(purchases.name) == .orderedSame }) {
            let beforeBroadTab = tabs.firstIndex { $0.criteria == subscriptions.criteria || $0.id == notifications.id }
            tabs.insert(purchases, at: beforeBroadTab ?? tabs.endIndex)
        }
        return tabs
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
