import Foundation

/// WebKit blockers apply to the exact resource identified in a received message.
nonisolated enum MailTrackingPixelRules {
    static func encoded(for urls: [String]) throws -> String {
        let rules: [[String: Any]] = Set(urls).sorted().map { url in
            ["trigger": ["url-filter": "^" + NSRegularExpression.escapedPattern(for: url) + "$",
                         "url-filter-is-case-sensitive": true],
             "action": ["type": "block"]]
        }
        let data = try JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated extension MailMessage {
    /// Older workspace responses stored an empty Gmail body or just Graph's
    /// bodyPreview alongside the original HTML. Repair those cached alternatives
    /// before search, reply quoting and message-list rows use them.
    mutating func restoreReceivedText(provider: String? = nil) {
        guard !isDraft, mailbox != .outbox else { return }
        var plain = paragraphs.joined(separator: "\n\n")
        let empty = plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let html = receivedHTML {
            let copiedPreview = paragraphs.count == 1 && plain == preview
            let mayBeGraphPreview = copiedPreview && (provider == "microsoft" || (provider == nil && backendMessageID != nil))
            if empty || plain == html || mayBeGraphPreview {
                let visible = Self.visibleText(in: html)
                let snippetInHTML = (plain.contains("&") || plain.contains("<")) && html.contains(plain)
                if !visible.isEmpty && (empty || plain == html || provider == "microsoft" || snippetInHTML ||
                    visible.hasPrefix(plain.trimmingCharacters(in: .whitespacesAndNewlines))) {
                    paragraphs = [visible]
                    plain = visible
                }
            }
        }

        if preview.contains("&"), preview.contains(";"), !plain.contains(preview) {
            let literal = preview.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let decoded = Self.visibleText(in: "<p>\(literal)</p>")
            if !decoded.isEmpty { preview = decoded }
        }
        if bodyHTML != nil, preview.contains("<"), !plain.contains(preview),
           preview.range(of: #"</?[a-zA-Z][^>]*>"#, options: .regularExpression) != nil {
            preview = Self.visibleText(in: preview)
        }
        if preview.isEmpty && !plain.isEmpty {
            preview = String(plain.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
        }
        if bodyHTML != nil && plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !preview.isEmpty {
            paragraphs = [preview]
        }
    }

    /// A local DOM gives us entity decoding and tolerant HTML parsing without a
    /// browser, resource fetching, or HTML attributed-string import.
    private static func visibleText(in html: String) -> String {
        guard let document = MailHTMLDocument(html), let root = document.root else { return "" }
        let omitted = ["head", "style", "script", "template", "iframe", "object"]
        let blocks = ["p", "div", "li", "tr", "section", "article", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"]
        var text = ""
        func visit(_ node: MailHTMLNode) {
            if let value = node.text {
                text += value
                return
            }
            guard let name = node.tag, !omitted.contains(name) else { return }
            if name == "br" || (blocks.contains(name) && !text.hasSuffix("\n")) { text += "\n" }
            for child in node.children { visit(child) }
            if blocks.contains(name) && !text.hasSuffix("\n") { text += "\n" }
            if name == "td" || name == "th" { text += " " }
        }
        visit(root)
        return text.split(whereSeparator: \.isNewline).map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Bounded, local extraction of the visible author's text, omitting HTML replies,
/// hidden preheaders and common provider quote containers.
nonisolated enum MailAuthoredText {
    private static let maxTextBytes = 32_768
    private static let invisibleStyle = regex(#"(?i)(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*(?:hidden|collapse)|opacity\s*:\s*0(?:\.0+)?|max-height\s*:\s*0(?:px)?)\s*(?:!important\s*)?(?:;|$)"#)
    private static let simpleSelector = regex(#"^(?:[A-Za-z][\w-]*)?([.#][\w-]+)$"#)

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func prefix(_ string: String, bytes: Int) -> String {
        String(decoding: string.utf8.prefix(bytes), as: UTF8.self)
    }

    static func visibleHTML(_ html: String) -> String {
        guard !Task.isCancelled, html.utf8.count <= 384 * 1_024,
              html.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let document = MailHTMLDocument(html), let root = document.root else { return "" }

        var hiddenSelectors: Set<String> = []
        for style in document.styleSheets {
            for rule in style.split(separator: "}") {
                let blocks = rule.split(separator: "{", omittingEmptySubsequences: false)
                guard blocks.count >= 2, let declarations = blocks.last,
                      matches(invisibleStyle, in: String(declarations)) else { continue }
                for part in blocks[blocks.count - 2].split(separator: ",") {
                    let selector = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let match = simpleSelector.firstMatch(in: selector, range: NSRange(selector.startIndex..., in: selector)),
                       let range = Range(match.range(at: 1), in: selector) { hiddenSelectors.insert(String(selector[range])) }
                }
            }
        }
        let omitted: Set<String> = ["head", "script", "style", "template", "iframe", "object", "blockquote", "noscript", "title"]
        let blocks: Set<String> = ["p", "div", "li", "tr", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6"]
        let skipClasses: Set<String> = ["gmail_quote", "gmail_quote_container", "yahoo_quoted", "moz-cite-prefix", "preheader", "previewtext"]
        var text = ""
        var reachedReply = false
        func visit(_ node: MailHTMLNode, depth: Int) {
            guard depth < 96, !reachedReply, !Task.isCancelled, text.utf8.count < maxTextBytes else { return }
            if let value = node.text {
                text += prefix(value, bytes: maxTextBytes - text.utf8.count)
                return
            }
            guard let name = node.tag, !omitted.contains(name) else { return }
            let id = node.attribute("id") ?? ""
            if ["divrplyfwdmsg", "x_divrplyfwdmsg", "ms-outlook-mobile-reference-message"].contains(id.lowercased()) {
                reachedReply = true
                return
            }
            let classes = (node.attribute("class") ?? "").split(whereSeparator: \.isWhitespace)
            guard node.attribute("hidden") == nil, node.attribute("aria-hidden")?.lowercased() != "true",
                  !hiddenSelectors.contains("#" + id), !classes.contains(where: { skipClasses.contains($0.lowercased()) || hiddenSelectors.contains("." + $0) }),
                  !matches(invisibleStyle, in: node.attribute("style") ?? "") else { return }
            if (blocks.contains(name) || name == "br") && !text.hasSuffix("\n") { text += "\n" }
            for child in node.children { visit(child, depth: depth + 1) }
            if blocks.contains(name) && !text.hasSuffix("\n") { text += "\n" }
            if name == "td" || name == "th" { text += " " }
        }
        visit(root, depth: 0)
        return text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
