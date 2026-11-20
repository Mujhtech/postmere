import Foundation

extension MailMessage {
    nonisolated var isSubscriptionMail: Bool {
        guard isIncomingCategoryCandidate else { return false }
        if hasMailingListID == true || unsubscribeHeaders?.listUnsubscribe.contains(where: { !$0.isEmpty }) == true { return true }
        if hasCategory(MailCategoryPatterns.subscriptionCategories) { return true }
        return MailCategoryPatterns.matches(MailCategoryPatterns.mailingList, in: subject)
    }

    nonisolated var isPurchaseMail: Bool {
        guard isIncomingCategoryCandidate else { return false }
        if providerLabelIDs.contains("CATEGORY_PURCHASES") || hasCategory(MailCategoryPatterns.purchaseCategories) { return true }
        if MailCategoryPatterns.matches(MailCategoryPatterns.purchaseSubject, in: subject) { return true }
        return MailCategoryPatterns.matches(MailCategoryPatterns.purchasePreview, in: preview)
    }

    private nonisolated var isIncomingCategoryCandidate: Bool {
        // Older Gmail caches can still carry SPAM with Archive as their local mailbox.
        !isOutgoing && !isDeletedOnProvider && (mailbox == .inbox || mailbox == .archive)
            && !providerLabelIDs.contains("SPAM")
    }

    private nonisolated func hasCategory(_ names: Set<String>) -> Bool {
        providerCategories?.contains { names.contains($0.lowercased()) } == true
    }
}

private nonisolated enum MailCategoryPatterns {
    static let subscriptionCategories: Set<String> = ["subscriptions", "mailing lists", "newsletters"]
    static let purchaseCategories: Set<String> = ["purchases", "receipts", "orders"]

    // Only bounded subject and snippet text is examined on the inbox indexing path.
    static let mailingList = expression(
        #"(?:(?:the|your|our)\s+)?(?:[^:!?]{1,45}\s+)?(?:newsletter|(?:weekly|daily|monthly) digest)(?:\s*[:|—#–-]|\s+for\b|\s*$)"#
    )
    static let purchaseSubject = expression(
        #"your\s+(?:(?:[\p{L}0-9&.'’-]+)\s+){0,3}(?:receipt|invoice)(?:\s*[:#—–-]|\s+(?:from|for|is ready|is available)\b|\s*$)"#,
        #"(?:receipt|invoice)\s*(?:#|no\.|number\b|[0-9]|from\b|for\b|attached\b|$)"#,
        #"(?:order|payment|purchase|shipping|transaction) (?:confirmation|receipt)\b(?!\s+(?:code|template)\b)"#,
        #"(?:(?:your (?:[\p{L}0-9.&’-]+ ){0,2})?order\s*(?:#|no\.\s*)[A-Z0-9][\w-]+)"#,
        #"(?:your\s+)?(?:order|package|shipment)\s+(?:#[\w-]+\s+)?(?:(?:has|is|was)\s+)?(?:been\s+)?(?:confirmed|shipped|delivered|on its way|out for delivery)\b"#,
        #"payment (?:received|successful)\b"#,
        #"thank(?:s| you) for (?:your (?:purchase|order|payment)|shopping with)\b"#
    )
    static let purchasePreview = expression(
        #"thank(?:s| you) for your (?:purchase|payment)\b"#,
        #"we(?:'ve| have) received your (?:order|payment)\b"#,
        #"your payment (?:has been|was) received\b"#,
        #"your order (?:has shipped|has been confirmed)\b"#
    )

    private static func expression(_ alternatives: String...) -> NSRegularExpression {
        let pattern = #"^\s*(?:"# + alternatives.joined(separator: "|") + ")"
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    static func matches(_ pattern: NSRegularExpression, in input: String) -> Bool {
        guard !input.isEmpty else { return false }
        let text = String(decoding: input.utf8.prefix(400), as: UTF8.self)
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
