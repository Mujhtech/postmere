#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Finds web links and email addresses in plain message text so they can be
/// clicked. Only https, http and mailto links are made; anything else stays text.
nonisolated enum MailLinkDetector {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private final class Box { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2_000
        return cache
    }()

    /// Allowed destinations for a detected link.
    static func safe(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "http": url.host?.contains(".") == true && url.user == nil && url.password == nil
        case "mailto": true
        default: false
        }
    }

    /// `text` with links marked and underlined; the reader's tint colours them.
    static func attributed(_ text: String) -> AttributedString {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        var result = AttributedString(text)
        if text.count <= 100_000, let detector, text.contains(where: { $0 == "." || $0 == "@" }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, safe(url), let span = Range(match.range, in: text),
                      let lower = AttributedString.Index(span.lowerBound, within: result),
                      let upper = AttributedString.Index(span.upperBound, within: result) else { continue }
                result[lower..<upper].link = url
                result[lower..<upper].underlineStyle = .single
            }
        }
        cache.setObject(Box(result), forKey: key)
        return result
    }

    /// Adds links to formatted text where the sender left URLs as plain text.
    static func link(_ text: NSMutableAttributedString) {
        guard let detector, text.length <= 200_000 else { return }
        let whole = NSRange(location: 0, length: text.length)
        for match in detector.matches(in: text.string, range: whole) {
            guard let url = match.url, safe(url),
                  text.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            text.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
        }
    }
}
