import AppKit

/// Describes one native text replacement, keeping text-system undo in charge.
struct MarkdownTextReplacement {
    let range: NSRange
    let content: NSAttributedString
    let typingAttributes: [NSAttributedString.Key: Any]
}

enum MarkdownSubstitutions {
    private static let blockKind = NSAttributedString.Key("PostmereMarkdownBlockKind")
    private static let baseFont = NSAttributedString.Key("PostmereMarkdownBaseFont")
    private static let baseParagraph = NSAttributedString.Key("PostmereMarkdownBaseParagraph")
    private static let baseBackground = NSAttributedString.Key("PostmereMarkdownBaseBackground")

    static func replacement(
        in content: NSAttributedString,
        selection: NSRange,
        insertedText: String,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> MarkdownTextReplacement? {
        guard selection.length == 0, selection.location <= content.length,
              insertedText.count == 1 else { return nil }
        let string = content.string as NSString
        let paragraph = string.paragraphRange(for: selection)
        let prefixRange = NSRange(location: paragraph.location, length: selection.location - paragraph.location)
        let prefix = string.substring(with: prefixRange)

        // Fenced code stays literal until another fence is typed on its own line.
        if prefix == "```", insertedText == "`" {
            var attributes = typingAttributes
            if attributes[blockKind] as? String == "code" {
                attributes = restoredAttributes(attributes)
            } else {
                attributes = rememberBase(attributes, kind: "code")
                let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                attributes[.backgroundColor] = NSColor.controlBackgroundColor
            }
            return MarkdownTextReplacement(range: prefixRange, content: NSAttributedString(string: ""), typingAttributes: attributes)
        }
        if typingAttributes[blockKind] as? String == "code" { return nil }

        if insertedText == " ",
           let block = blockReplacement(prefix: prefix, range: prefixRange, attributes: typingAttributes) {
            // A block prefix only changes a fresh paragraph, not text after the caret.
            let remainder = NSRange(location: selection.location, length: NSMaxRange(paragraph) - selection.location)
            if string.substring(with: remainder).trimmingCharacters(in: .newlines).isEmpty { return block }
        }

        guard ["*", "_", "`"].contains(insertedText) else { return nil }
        let rules: [(String, InlineStyle)] = [
            (#"(?<![\\\p{L}\p{N}])\*\*\*([^*\r\n]+)\*\*\*$"#, .boldItalic),
            (#"(?<![\\*])\*\*([^*\r\n]+)\*\*$"#, .bold),
            (#"(?<![\\*])\*([^*\r\n]+)\*$"#, .italic),
            (#"(?<![\\\p{L}\p{N}_])_([^_\r\n]+)_$"#, .italic),
            (#"(?<![\\`])`([^`\r\n]+)`$"#, .code)
        ]
        for (pattern, style) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { continue }
            let inner = match.range(at: 1)
            let text = (prefix as NSString).substring(with: inner)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  text.first?.isWhitespace == false, text.last?.isWhitespace == false else { continue }
            let absoluteInner = NSRange(location: prefixRange.location + inner.location, length: inner.length)
            let formatted = NSMutableAttributedString(attributedString: content.attributedSubstring(from: absoluteInner))
            let all = NSRange(location: 0, length: formatted.length)
            formatted.enumerateAttribute(.font, in: all) { value, range, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: 14)
                formatted.addAttribute(.font, value: fontForStyle(style, original: font), range: range)
            }
            if style == .code { formatted.addAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, range: all) }
            return MarkdownTextReplacement(
                range: NSRange(location: prefixRange.location + match.range.location, length: match.range.length),
                content: formatted,
                typingAttributes: typingAttributes
            )
        }
        return nil
    }

    /// Handle Return before AppKit inserts it, so list continuation is one undoable edit.
    static func newlineReplacement(
        in content: NSAttributedString,
        selection: NSRange,
        typingAttributes: [NSAttributedString.Key: Any]
    ) -> MarkdownTextReplacement? {
        guard selection.length == 0, selection.location <= content.length else { return nil }
        let string = content.string as NSString
        let paragraphRange = string.paragraphRange(for: selection)
        let line = string.substring(with: paragraphRange).trimmingCharacters(in: .newlines)
        let paragraph = typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default

        if let marker = listMarker(in: line), paragraph.headIndent > 0 {
            let remainder = (line as NSString).substring(from: marker.length)
            if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                let attributes = restoredAttributes(typingAttributes)
                return MarkdownTextReplacement(
                    range: NSRange(location: paragraphRange.location, length: (line as NSString).length),
                    content: NSAttributedString(string: ""), typingAttributes: attributes
                )
            }
            let nextMarker = marker.number.map { "\($0 + 1).\t" } ?? "•\t"
            return MarkdownTextReplacement(
                range: selection,
                content: NSAttributedString(string: "\n" + nextMarker, attributes: typingAttributes),
                typingAttributes: typingAttributes
            )
        }

        if paragraph.headerLevel > 0 {
            let attributes = restoredAttributes(typingAttributes)
            return MarkdownTextReplacement(range: selection, content: NSAttributedString(string: "\n", attributes: attributes), typingAttributes: attributes)
        }
        if typingAttributes[blockKind] as? String == "quote", line.trimmingCharacters(in: .whitespaces).isEmpty {
            return MarkdownTextReplacement(range: selection, content: NSAttributedString(string: ""), typingAttributes: restoredAttributes(typingAttributes))
        }
        return nil
    }

    private enum InlineStyle { case bold, italic, boldItalic, code }

    private static func fontForStyle(_ style: InlineStyle, original: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        switch style {
        case .bold: return manager.convert(original, toHaveTrait: .boldFontMask)
        case .italic: return manager.convert(original, toHaveTrait: .italicFontMask)
        case .boldItalic: return manager.convert(original, toHaveTrait: [.boldFontMask, .italicFontMask])
        case .code: return NSFont.monospacedSystemFont(ofSize: original.pointSize, weight: .regular)
        }
    }

    private static func blockReplacement(prefix: String, range: NSRange, attributes: [NSAttributedString.Key: Any]) -> MarkdownTextReplacement? {
        var formatted = attributes
        var replacement = ""
        let paragraph = ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        let marker = String(prefix.dropLast())
        if (1...6).contains(marker.count), marker.allSatisfy({ $0 == "#" }) {
            formatted = rememberBase(attributes, kind: "heading")
            paragraph.headerLevel = marker.count
            paragraph.paragraphSpacing = 6
            let sizes: [CGFloat] = [28, 24, 20, 18, 16, 14]
            formatted[.font] = NSFont.systemFont(ofSize: sizes[marker.count - 1], weight: .bold)
        } else if prefix == "> " {
            formatted = rememberBase(attributes, kind: "quote")
            paragraph.firstLineHeadIndent = 20
            paragraph.headIndent = 20
        } else if prefix == "* " || prefix == "- " || prefix == "1. " {
            formatted = rememberBase(attributes, kind: "list")
            replacement = prefix == "1. " ? "1.\t" : "•\t"
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 22
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
        } else {
            return nil
        }
        formatted[.paragraphStyle] = paragraph
        return MarkdownTextReplacement(range: range, content: NSAttributedString(string: replacement, attributes: formatted), typingAttributes: formatted)
    }

    private static func rememberBase(_ attributes: [NSAttributedString.Key: Any], kind: String) -> [NSAttributedString.Key: Any] {
        var result = attributes
        if result[baseFont] == nil { result[baseFont] = result[.font] ?? NSFont.systemFont(ofSize: 14) }
        if result[baseParagraph] == nil { result[baseParagraph] = result[.paragraphStyle] ?? NSParagraphStyle.default }
        if result[baseBackground] == nil, let background = result[.backgroundColor] { result[baseBackground] = background }
        result[blockKind] = kind
        return result
    }

    private static func restoredAttributes(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attributes
        result[.font] = result[baseFont] ?? NSFont.systemFont(ofSize: 14)
        let paragraph = ((result[baseParagraph] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.headerLevel = 0
        paragraph.textLists = []
        result[.paragraphStyle] = paragraph
        result[.backgroundColor] = result[baseBackground]
        for key in [blockKind, baseFont, baseParagraph, baseBackground] { result.removeValue(forKey: key) }
        return result
    }

    private static func listMarker(in line: String) -> (length: Int, number: Int?)? {
        if line.hasPrefix("•\t") { return (2, nil) }
        guard let expression = try? NSRegularExpression(pattern: #"^(\d{1,6})\.\t"#),
              let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              let number = Int((line as NSString).substring(with: match.range(at: 1))), number < 999_999 else { return nil }
        return (match.range.length, number)
    }
}
