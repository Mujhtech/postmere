import Foundation

/// Finds an English request in the sender's own words. Runs on local message data.
nonisolated enum MailReplyIntent {
    private static let automatedAddress = pattern(#"(?:^|[._+\-])(?:no[._-]?reply|do[._-]?not[._-]?reply|donotreply|notifications?|mailer[._-]?daemon|postmaster|newsletters?|digest|marketing|promotions?|automated|alerts?)(?:$|[._+\-])"#)
    private static let automatedSubject = pattern(#"\b(?:one[ -]time (?:code|password|passcode)|(?:verification|security|sign[ -]?in|login) code|password reset|verify your (?:email|identity|account)|out of (?:the )?office|automatic reply|auto[ -]?reply|delivery (?:status notification|failure)|order confirmation|order receipt|unsubscribe)\b"#)
    private static let excludedLabels: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS", "CATEGORY_UPDATES", "SPAM", "TRASH"]
    private static let quotation = pattern(#"^(?:on\s+.{1,450}\bwrote\s*:|am\s+.{1,450}\bschrieb\b.{0,240}:|.{1,160}\bschrieb am\b.{1,300}:|begin forwarded message:|anfang der weitergeleiteten nachricht:|[-_]{2,}\s*(?:(?:original|forwarded) message|(?:ursprüngliche|weitergeleitete) nachricht|originalnachricht)|(?:from|von):\s+[^\n]*@)"#)
    private static let senderHeader = pattern(#"^(?:from|von)\s*:\s*\S"#)
    private static let replyHeader = pattern(#"^(?:sent|gesendet|datum|date|to|an|subject|betreff)\s*:"#)
    private static let noResponse = alternatives([
        #"\bno (?:need to (?:respond|reply|answer)|(?:response|reply|action) (?:is )?(?:needed|required|necessary))\b"#,
        #"\b(?:do not|don['’]t) (?:(?:have|need) to )?(?:respond|reply)\b"#,
        #"\bthis (?:is an? )?(?:automated|automatically generated) (?:message|email)\b"#,
        #"\b(?:manage (?:your )?(?:email|subscription) preferences|receiving this (?:email|message) because|unsubscribe from (?:this|these|our|future) (?:emails?|list|updates))\b"#,
        #"\b(?:enter|use) (?:this|the following|your) (?:verification|one.time|sign.in|security) code\b"#
    ])
    private static let elective = alternatives([
        #"\bif (?:you (?:have (?:any )?questions|need (?:any )?help|would like|want (?:to|me to))|(?:anything|something) (?:comes up|is unclear))\b"#,
        #"\b(?:feel free|don['’]t hesitate) to\b"#,
        #"\b(?:how (?:did we do|was your experience)|rate your (?:purchase|experience)|(?:shop|buy|order) now|(?:ready|want|would you like) to (?:shop|save|unsubscribe|upgrade|unlock))\b"#,
        #"\b(?:can you believe it|did you know|why not try)\b"#
    ])
    private static let ask = alternatives([
        #"\b(?:can|could|would|will) you\s+\p{L}+\b"#,
        #"\b(?:please|kindly)\s+(?:respond|reply|confirm|send|share|review|approve|choose|provide|return|sign|advise|check|tell|update)\b"#,
        #"\blet (?:me|us) know\b"#,
        #"\b(?:i|we)(?:['’]d| would) (?:like|appreciate) your (?:thoughts|feedback|input|approval)\b"#,
        #"\b(?:i|we) need (?:your (?:feedback|approval|response|input|confirmation)|you to (?:review|confirm|send|reply|approve|choose|share))\b"#
    ])
    private static let question = alternatives([
        #"^(?:what|when|where|which|how|who|why)\b"#,
        #"^(?:do|did|are|have|were|would|can|could|will|should)\s+(?:you|we|i)\b"#,
        #"^(?:can|could|would|does|did|is|will|are)\s+.{0,100}\b(?:work|available|free|okay|ok|suit|look (?:right|good)|still on|correct)\b"#,
        #"^(?:any (?:thoughts|updates?|preferences?|feedback|objections)|are there any|thoughts on)\b"#
    ])
    private static let greeting = pattern(#"^(?:(?:hi|hey|hello|dear)\s+[\p{L} '\-]{1,36},\s*|(?:hi|hey|hello)[,!]\s*)"#)
    private static let replySubject = pattern(#"^\s*(?:re|aw|wg|fw|fwd)\s*:"#)

    static func request(in message: MailMessage) -> String? {
        guard !message.isFromAccountOwner else { return nil }
        return candidates(in: message)?.first
    }

    /// Sent messages supply authorship evidence for unmarked quoted text in later replies.
    /// An empty array means a sent body was examined and contained no request.
    static func candidates(in message: MailMessage) -> [String]? {
        guard !Task.isCancelled, !message.isDraft, !message.isDeletedOnProvider,
              ![Mailbox.trash, .outbox, .junk].contains(message.mailbox) else { return nil }
        let outgoing = message.isFromAccountOwner
        let subject = String(message.subject.prefix(320))
        if !outgoing {
            let local = String(message.senderEmail.prefix { $0 != "@" })
            guard message.unsubscribeHeaders?.listUnsubscribe.isEmpty != false,
                  !message.providerLabelIDs.contains(where: { excludedLabels.contains($0.uppercased()) }),
                  !matches(automatedAddress, local), !matches(automatedSubject, subject),
                  !isCopyOnly(message) else { return nil }
        }
        let empty: [String]? = outgoing ? [] : nil
        var plain = ""
        for paragraph in message.paragraphs {
            let remaining = 8_192 - plain.utf8.count
            guard remaining > 2 else { break }
            plain += String(decoding: paragraph.utf8.prefix(remaining - 2), as: UTF8.self) + "\n\n"
        }
        if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { plain = String(message.preview.prefix(512)) }
        let directSubject = matches(replySubject, subject) ? nil : excerpts(in: subject).first
        let hasClue = directSubject != nil || plain.contains("?") || matches(ask, plain)
        let body: String
        if let html = message.bodyHTML, !html.isEmpty {
            // Skip DOM parsing for ordinary non-actionable mail. A positive flattened
            // alternative must be checked against the original to exclude quoted HTML.
            guard hasClue || plain.isEmpty else { return empty }
            body = MailAuthoredText.visibleHTML(html)
            guard !body.isEmpty else { return empty }
        } else {
            guard hasClue else { return empty }
            body = plain
        }
        let authored = authoredParagraphs(in: body)
        if !outgoing, matches(noResponse, subject) || authored.contains(where: { matches(noResponse, $0) }) { return nil }
        var candidates = authored.flatMap { excerpts(in: $0) }
        if let directSubject, !candidates.contains(directSubject) { candidates.append(directSubject) }
        return candidates.isEmpty ? empty : candidates
    }

    private static func isCopyOnly(_ message: MailMessage) -> Bool {
        guard let account = message.providerAccountEmail?.lowercased(), !account.isEmpty else { return false }
        func includesAccount(_ entries: [String]) -> Bool {
            entries.contains {
                let address = $0.split(separator: "<").last.map(String.init) ?? $0
                return address.trimmingCharacters(in: CharacterSet(charactersIn: "> \t\n")).lowercased() == account
            }
        }
        return (includesAccount(message.ccRecipients) || includesAccount(message.bccRecipients)) && !includesAccount(message.toRecipients)
    }

    private static func authoredParagraphs(in text: String) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        let lines = String(decoding: text.utf8.prefix(8_192), as: UTF8.self)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() {
            if matches(quotation, line) || line == "--" { break }
            if matches(senderHeader, line), lines.dropFirst(index + 1).prefix(4).contains(where: { matches(replyHeader, $0) }) { break }
            // Mail clients may wrap "On … wrote:" or "Am … schrieb …:" across lines.
            if line.lowercased().hasPrefix("on ") || line.lowercased().hasPrefix("am ") {
                let wrapped = lines[index...].prefix(3).prefix(while: { !$0.isEmpty }).joined(separator: " ")
                if matches(quotation, wrapped) { break }
            }
            if line.isEmpty || line.hasPrefix(">") {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                continue
            }
            if !current.isEmpty { current += " " }
            current += line
            if line.last.map({ ".?!".contains($0) }) == true {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    private static func excerpts(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { raw, _, _, _ in
            guard let raw else { return }
            var sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intro = greeting.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)),
               let range = Range(intro.range, in: sentence) { sentence.removeSubrange(range) }
            guard (4...400).contains(sentence.utf8.count), !matches(elective, sentence),
                  matches(ask, sentence) || (sentence.hasSuffix("?") && matches(question, sentence)) else { return }
            result.append(sentence)
        }
        return result
    }

    private static func alternatives(_ parts: [String]) -> NSRegularExpression {
        pattern(parts.joined(separator: "|"))
    }

    private static func pattern(_ source: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
