import Foundation

/// The quoted history at the end of a reply or forward ("On Mon, Ada wrote:" and
/// what follows), so the composer can fold it away while the person writes. It
/// is only hidden: the message is always sent with it.
nonisolated enum MailQuotedReply {
    /// Where the quoted history begins, including the blank lines before it.
    static func quoteStart(in body: String) -> String.Index? {
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(of: "\n") ?? body.endIndex
            let line = body[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if isQuoteHeader(line) {
                var start = lineStart
                while start > body.startIndex {
                    let previous = body.index(before: start)
                    guard body[previous].isNewline || body[previous] == " " || body[previous] == "\t" else { break }
                    start = previous
                }
                return start
            }
            lineStart = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        return nil
    }

    static func isQuoteHeader(_ line: String) -> Bool {
        (line.hasPrefix("On ") && line.hasSuffix("wrote:"))
            || line.hasPrefix("---------- Forwarded message")
            || line.hasPrefix("-----Original Message-----")
    }

    /// The part the person writes and the quoted history after it, which joined
    /// give back the body exactly. Nil when there is no quote.
    static func split(_ body: String) -> (head: String, quote: String)? {
        guard let start = quoteStart(in: body) else { return nil }
        let quote = String(body[start...])
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (String(body[..<start]), quote)
    }

    /// "On 24 Nov, Ada wrote:" or "Forwarded message", for the folded bar.
    static func title(of quote: String) -> String {
        let line = quote.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        if line.hasPrefix("---------- Forwarded message") || line.hasPrefix("-----Original Message-----") { return "Forwarded message" }
        return line
    }

    /// Joins an edited head back to the quote it was split from.
    static func join(head: String, quote: String) -> String {
        guard !quote.isEmpty else { return head }
        // Keep the quote on its own lines however the head now ends.
        let separated = quote.first?.isNewline == true || head.isEmpty || head.last?.isNewline == true
        return separated ? head + quote : head + "\n\n" + quote
    }
}
