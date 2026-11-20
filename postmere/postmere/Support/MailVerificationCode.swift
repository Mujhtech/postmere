import Foundation

/// Reads only the current message's visible content. Values are kept as strings so leading zeroes survive copying.
nonisolated enum MailVerificationCode {
    private static let accountAction = #"(?i:sign[\s‑-]?in|log[\s‑-]?in|(?:verify|confirm)\s+(?:(?:your|this)\s+)?(?:email(?:\s+address)?|identity|account|login)|reset\s+(?:your\s+)?password)"#
    private static let label = #"(?i:\b(?:(?:(?:one[\s‑-]?time|single[\s‑-]?use)(?:\s+(?:verification|security))?|verification|confirmation|authentication|security|log[\s‑-]?in|sign[\s‑-]?in|two[\s‑-]?(?:factor|step)(?:\s+(?:authentication|verification))?|2fa)\s+(?:code|password|passcode|pin)|(?:otp|totp)(?:\s+code)?|passcode)\b)"#
    private static let codeForAction = #"(?i:\bcode\s+(?:to|for)\s+)"# + accountAction + #"\b"#
    private static let authCodeLabel = regex(label + "|" + codeForAction)
    private static let intent = regex(label + "|" + codeForAction + #"|(?i:\b(?:verify|confirm)\s+(?:your|this)\s+(?:email|identity|account|login|sign[\s‑-]?in)\b|\bpassword reset\b|\breset (?:your )?password\b|\b(?:sign[\s‑-]?in|log[\s‑-]?in)\s+(?:to|code)\b)"#)
    private static let token = #"(?<![\p{L}\p{N}_@/‑-])([0-9]{3}[ ‑-][0-9]{3}|[0-9]{4}[ ‑-][0-9]{4}|[0-9](?: [0-9]){3,7}|[A-Za-z0-9]{2,4}-[A-Za-z0-9]{2,4}|[A-Za-z0-9]{4,8})(?![\p{L}\p{N}_@/‑-]|\.\w)"#
    private static let connector = #"\s*(?:(?i:for\s+[\p{L}\p{N} .'-]{1,40}?\s+is|is(?:\s+below)?|below)\b\s*)?[:：=#–—-]?\s*["“]?"#
    private static let afterLabel = regex("(?:" + label + "|" + codeForAction + ")" + connector + token)
    private static let googleCode = regex(#"(?i:\bG-)([0-9]{6})\s+(?i:is\s+your\s+Google\s+verification\s+code\b)"#)
    private static let reservation = regex(#"(?i)\b(?:reservations?|booking|itinerary|flight confirmation|order confirmation)\b"#)
    private static let confirmation = regex(#"(?i)\bconfirmation\s+(?:code|pin)\b"#)
    private static let beforeLabel = regex(token + #"\s+(?i:is\s+(?:your|the|a)\s+(?:[\p{L}\p{N}'’-]+\s+){0,3})"# + label)
    private static let genericLabel = #"(?i:(?:^|\b(?:your|this|the|enter|use)\s+)code\b)"#
    private static let afterGenericCode = regex(genericLabel + connector + token)
    private static let useToVerify = regex(#"(?i:\b(?:enter|use|type))\s+"# + token + #"\s+(?i:to)\s+"# + accountAction)
    private static let directLabels = [afterLabel, beforeLabel, useToVerify, googleCode]
    private static let codePrompt = regex("(?:" + label + "|" + codeForAction + "|" + genericLabel + #")\s*(?i:is|below|is below|to continue)?[ .:：–—-]*$"#)
    private static let greeting = regex(#"(?i)^(?:hi|hello|dear)(?:\s+[\p{L} '-]{1,35})?[,!]?$"#)
    private static let isolated = regex("^" + token + "$")
    private static let alternatives = regex(token + #"\s*(?:/|(?i:\bor\b|\band\b))\s*"# + token)
    private static let quotedSubject = regex(#"(?i)^\s*(?:re|fw|fwd)\s*:"#)
    private static let replyBoundary = regex(#"(?i)^(?:on\s+.{1,500}\s+wrote\s*:|begin forwarded message\s*:|-{2,}\s*(?:original|forwarded) message|from:\s+.+@)"#)
    private static let htmlHint = regex(#"(?i)code|\botp\b|password|\bpin\b|verif|confirm|authenticat|log[\s‑-]?in|sign[\s‑-]?in"#)
    private static let maxTextBytes = 32_768

    static func detect(subject: String, paragraphs: [String], html: String?, preview: String = "") -> String? {
        guard !Task.isCancelled else { return nil }
        let subject = prefix(subject, bytes: 1_024)
        guard !matches(quotedSubject, in: subject) else { return nil }
        let body: String
        if let html, !html.isEmpty {
            // Providers may derive the plain alternative and snippet from hidden HTML or quoted replies.
            // When HTML exists, extract from the visible DOM and never substitute those flattened alternatives.
            let sample = prefix(html, bytes: maxTextBytes)
            guard matches(intent, in: subject) || matches(htmlHint, in: sample) ||
                    paragraphs.prefix(2).contains(where: { matches(htmlHint, in: prefix($0, bytes: 2_048)) }) else { return nil }
            body = MailAuthoredText.visibleHTML(html)
        } else {
            var text = ""
            for paragraph in paragraphs {
                let remaining = maxTextBytes - text.utf8.count
                guard remaining > 1 else { break }
                text += prefix(paragraph, bytes: remaining - 1) + "\n"
            }
            body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? prefix(preview, bytes: 1_024) : text
        }
        guard !Task.isCancelled else { return nil }
        let lines = body.split(whereSeparator: \.isNewline).map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }.prefix { !matches(replyBoundary, in: $0) }.filter { !$0.hasPrefix(">") }
        let visible = lines.joined(separator: "\n")
        let authSubject = matches(intent, in: subject)
        guard authSubject || matches(intent, in: visible) || matches(useToVerify, in: visible) else { return nil }

        if matches(reservation, in: subject) || matches(reservation, in: visible) {
            // In a reservation or purchase, a confirmation code commonly identifies the booking itself.
            let text = subject + "\n" + visible
            let otherContext = confirmation.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            guard matches(authCodeLabel, in: otherContext) || matches(useToVerify, in: otherContext) else { return nil }
        }
        var codes = Set<String>()
        for source in [subject, visible] {
            for pattern in directLabels {
                codes.formUnion(values(pattern, in: source))
            }
        }

        // Generic "code" labels need their own authentication context. A sign-in link in
        // a receipt footer does not turn an order number or coupon elsewhere into an OTP.
        var previous = subject
        var previousWasCode = false
        for line in lines {
            let explicitPrompt = matches(codePrompt, in: previous) && (authSubject || matches(intent, in: previous))
            if authSubject || matches(intent, in: line) || explicitPrompt {
                codes.formUnion(values(afterGenericCode, in: line))
            }
            let firstValueUnderSubject = authSubject && (previous == subject || matches(greeting, in: previous))
            let candidate = values(isolated, in: line).first
            let followsLabelledValue = candidate != nil && !codes.isEmpty && directLabels.contains { matches($0, in: previous) }
            if let candidate, explicitPrompt || firstValueUnderSubject || previousWasCode || followsLabelledValue {
                if !(candidate.count == 4 && (1900...2099).contains(Int(candidate) ?? 0)) { codes.insert(candidate) }
                previousWasCode = true
            } else {
                previousWasCode = false
            }
            if codes.count > 1 { return nil }
            previous = line
        }
        guard codes.count == 1, let result = codes.first else { return nil }
        for source in [subject, visible] {
            for pair in alternatives.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let pairCodes = Set((1...2).compactMap { code(in: source, range: pair.range(at: $0)) })
                if pairCodes.count > 1 && pairCodes.contains(result) { return nil }
            }
        }
        return result
    }

    private static func code(in source: String, range: NSRange) -> String? {
        guard let range = Range(range, in: source) else { return nil }
        let raw = String(source[range])
        let compact = raw.filter { $0.isLetter || $0.isNumber }
        guard (4...8).contains(compact.count), compact.contains(where: \.isNumber) else { return nil }
        if compact.allSatisfy(\.isNumber) {
            let groups = raw.split { !$0.isNumber }
            guard groups.allSatisfy({ $0.count == groups.first?.count }) else { return nil }
            return compact
        }
        return raw
    }

    private static func values(_ pattern: NSRegularExpression, in source: String) -> [String] {
        pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { code(in: source, range: $0.range(at: 1)) }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func prefix(_ string: String, bytes: Int) -> String {
        if string.utf8.count <= bytes { return string }
        return String(decoding: string.utf8.prefix(bytes), as: UTF8.self)
    }

}
