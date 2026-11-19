import Foundation

/// WebKit blockers apply to the exact resource identified in a received message.
enum MailTrackingPixelRules {
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
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement() else { return "" }
        let omitted = ["head", "style", "script", "template", "iframe", "object"]
        let blocks = ["p", "div", "li", "tr", "section", "article", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"]
        var text = ""
        func visit(_ node: XMLNode) {
            if node.kind == .text {
                text += node.stringValue ?? ""
                return
            }
            guard node.kind == .element, let name = node.localName?.lowercased(), !omitted.contains(name) else { return }
            if name == "br" || (blocks.contains(name) && !text.hasSuffix("\n")) { text += "\n" }
            for child in node.children ?? [] { visit(child) }
            if blocks.contains(name) && !text.hasSuffix("\n") { text += "\n" }
            if name == "td" || name == "th" { text += " " }
        }
        visit(root)
        return text.split(whereSeparator: \.isNewline).map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
