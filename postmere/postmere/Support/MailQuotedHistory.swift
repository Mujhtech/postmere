import Foundation
import WebKit

/// Only the reader uses this information. The original MIME alternatives remain intact.
nonisolated struct MailQuoteContext: Equatable, Sendable {
    struct Author: Equatable, Sendable {
        let name: String
        let address: String

        var displayName: String { name.isEmpty ? address : name }
    }

    let participants: [Author]
    let parent: Author?
    var hasReplyHeaders = false

    func disclosureTitle(attribution: String) -> String {
        let line = attribution.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressRange = line.range(of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive])
        var author: String?
        if let addressRange {
            let address = String(line[addressRange])
            author = participants.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }?.displayName ?? address
        } else if let intro = line.range(of: #"\s+wrote:\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            let attributionEnd = line[..<intro.lowerBound]
            // Match the whole trailing name, so "Ann" cannot match "Joann".
            if let known = participants.first(where: { person in
                guard !person.name.isEmpty,
                      let match = attributionEnd.range(of: person.name, options: [.anchored, .backwards, .caseInsensitive]) else { return false }
                return match.lowerBound == attributionEnd.startIndex || !attributionEnd[attributionEnd.index(before: match.lowerBound)].isLetter
            }) {
                author = known.displayName
            } else if let comma = attributionEnd.lastIndex(of: ",") {
                let name = attributionEnd[attributionEnd.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                if (1...90).contains(name.count), name.contains(where: \.isLetter),
                   !name.contains(where: \.isNumber) { author = name }
            }
        } else if line.isEmpty {
            author = parent?.displayName
        }
        if let author, !author.isEmpty { return "See more from \(author)" }
        return "See quoted message"
    }

    /// Require an attributed quote at the end. An unquoted answer after or between
    /// quoted lines stays in the original body, as do forwarded messages.
    func plainQuote(in text: String) -> (start: String.Index, title: String)? {
        var end = text.endIndex
        var hasContent = false
        func precedingLine() -> Substring? {
            guard end > text.startIndex else { return nil }
            let last = end
            let newline = text[..<end].lastIndex(where: \.isNewline)
            end = newline ?? text.startIndex
            return text[(newline.map { text.index(after: $0) } ?? text.startIndex)..<last]
        }
        while let line = precedingLine() {
            let trimmed = line.drop(while: \.isWhitespace)
            guard let first = trimmed.first else { continue }
            if first == ">" {
                if !hasContent { hasContent = trimmed.contains { !$0.isWhitespace && $0 != ">" } }
                continue
            }
            guard hasContent, trimmed.utf8.count <= 600 else { return nil }
            var attribution = trimmed.trimmingCharacters(in: .whitespaces)
            guard attribution.lowercased().hasSuffix("wrote:") else { return nil }
            var start = line.startIndex
            // Clients can wrap the attribution across successive physical lines.
            for _ in 0..<4 {
                if attribution.lowercased().hasPrefix("on ") {
                    if text[..<start].range(of: #"(?im)^\s*(?:-{2,}\s*Forwarded message\b|Begin forwarded message:)"#, options: .regularExpression) != nil { return nil }
                    return (start, disclosureTitle(attribution: attribution))
                }
                guard let previous = precedingLine(), previous.utf8.count <= 600 else { break }
                let fragment = previous.trimmingCharacters(in: .whitespaces)
                guard !fragment.isEmpty else { break }
                start = previous.startIndex
                attribution = "\(fragment) \(attribution)"
            }
            return nil
        }
        return nil
    }
}

@MainActor
struct MailQuoteThread {
    private var participants: [MailQuoteContext.Author] = []
    private var authorsByMessageID: [String: MailQuoteContext.Author] = [:]

    init(messages: [MailMessage]) {
        var seen: Set<String> = []
        for message in messages {
            let author = MailQuoteContext.Author(name: message.isOutgoing ? message.mailAccount.displayName : message.sender,
                                                 address: message.senderEmail)
            if seen.insert(author.address.lowercased()).inserted { participants.append(author) }
            if let id = message.rfcMessageID { authorsByMessageID[Self.normalizedID(id)] = author }
        }
        participants.sort { $0.name.count > $1.name.count }
    }

    func context(for message: MailMessage) -> MailQuoteContext? {
        if message.subject.range(of: #"^\s*(?:re:\s*)*(?:fw|fwd):"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        let replyID = message.inReplyTo ?? message.references.last
        return MailQuoteContext(participants: participants, parent: replyID.flatMap { authorsByMessageID[Self.normalizedID($0)] },
                                hasReplyHeaders: replyID != nil)
    }

    private static func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
    }
}

/// Runs in WebKit's isolated client world. The sender cannot supply Swift code or a
/// disclosure title. Moving the existing elements preserves links, images and styling.
@MainActor
final class MailHTMLQuoteDisclosure: NSObject, WKScriptMessageHandler {
    private let context: MailQuoteContext

    init(context: MailQuoteContext) { self.context = context }

    func install(in controller: WKUserContentController) {
        controller.add(self, contentWorld: .defaultClient, name: "quotedHistory")
        let hasReply = context.hasReplyHeaders || context.parent != nil
        let script = "const postmereHasReply = \(hasReply);\n" + Self.script
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let line = message.body as? String else { return }
        message.webView?.callAsyncJavaScript("globalThis.postmereQuoteTitle?.(title)",
                                             arguments: ["title": context.disclosureTitle(attribution: line)],
                                             in: message.frameInfo, in: .defaultClient, completionHandler: nil)
    }

    private static let script = #"""
    document.addEventListener('DOMContentLoaded', () => {
        const body = document.body;
        if (!body) return;
        const meaningful = node => {
            if (node.nodeType === Node.TEXT_NODE) return !!node.textContent.trim();
            if (node.nodeType !== Node.ELEMENT_NODE || node.matches('br,style,script,template,meta,link')) return false;
            return !!node.textContent.trim() || node.matches('img,hr,svg,video,table') || !!node.querySelector('img,hr,svg,video,table');
        };
        // Gmail and others put the sender's signature below the quote by default,
        // after a "--" delimiter line. A signature there does not count as an answer.
        const signature = node => {
            if (node.nodeType === Node.ELEMENT_NODE && node.matches('.gmail_signature,.gmail_signature_prefix,[data-smartmail="gmail_signature"],.moz-signature')) return true;
            const text = node.nodeType === Node.ELEMENT_NODE ? node.innerText : node.textContent;
            return (text ?? '').trim().split(/\r?\n/)[0].trim() === '--';
        };
        const hasFollowingContent = element => {
            for (let ancestor = element; ancestor && ancestor !== body; ancestor = ancestor.parentElement) {
                for (let sibling = ancestor.nextSibling; sibling; sibling = sibling.nextSibling) {
                    if (signature(sibling)) return false;
                    if (meaningful(sibling)) return true;
                }
            }
            return false;
        };
        const fold = (start, end, line) => {
            const preceding = document.createRange();
            preceding.selectNodeContents(body);
            preceding.setEndBefore(start);
            const forwarded = /(?:-{2,}\s*Forwarded message\b|Begin forwarded message:)/i;
            if (forwarded.test(line) || forwarded.test(preceding.toString())) return;
            const details = document.createElement('details');
            details.style.cssText = 'display:block!important;max-height:none!important;overflow:visible!important;';
            const summary = document.createElement('summary');
            summary.style.cssText = 'all:revert!important;display:list-item!important;width:fit-content!important;list-style-position:inside!important;cursor:pointer!important;font:13px -apple-system,sans-serif!important;color-scheme:light dark!important;color:var(--postmere-quote-ink, LinkText)!important;background:Canvas!important;margin:8px 0!important;';
            let title = 'See quoted message';
            const label = () => { summary.textContent = details.open ? 'Show less' : title; };
            globalThis.postmereQuoteTitle = value => { title = value; label(); };
            label();
            details.addEventListener('toggle', label);
            const range = document.createRange();
            range.setStartBefore(start);
            range.setEndAfter(end);
            const contents = range.extractContents();
            range.insertNode(details);
            details.append(summary, contents);
            window.webkit.messageHandlers.quotedHistory.postMessage(line);
        };
        const attributed = line => line.length <= 600 && /^On\s.+\swrote:\s*$/is.test(line);
        const previousContent = node => {
            let previous = node.previousSibling;
            while (previous && !meaningful(previous)) previous = previous.previousSibling;
            return previous;
        };
        const candidates = body.querySelectorAll('blockquote[type="cite" i],blockquote.gmail_quote,.gmail_quote blockquote');
        for (const quote of candidates) {
            if (hasFollowingContent(quote) || !meaningful(quote)) continue;
            let start = quote;
            let line = '';
            for (let node = quote; node && node !== body; node = node.parentElement) {
                const previous = previousContent(node);
                if (!previous) continue;
                const candidate = previous.textContent.trim();
                if (attributed(candidate) || (candidate.length <= 600 && previous.nodeType === Node.ELEMENT_NODE && previous.matches('.gmail_attr'))) {
                    start = previous;
                    line = candidate;
                }
                break;
            }
            if (!line && !postmereHasReply && !quote.closest('.gmail_quote')) continue;
            fold(start, quote, line);
            return;
        }
        // Cocoa HTML Writer exports each line of a Postmere RTF reply as a
        // paragraph, preserving literal > quote prefixes rather than a blockquote.
        // Take only a continuous tail of explicitly prefixed paragraphs.
        let end = body.lastChild;
        while (end && !meaningful(end)) end = end.previousSibling;
        let hasQuote = false;
        for (let node = end; node?.nodeName === 'P'; node = previousContent(node)) {
            if (node.querySelector('img,hr,svg,video,table')) return;
            const lines = node.innerText.trim().split(/\r?\n/).map(line => line.trim()).filter(Boolean);
            if (lines.length && lines.every(line => line.startsWith('>'))) {
                hasQuote ||= lines.some(line => /[^>\s]/.test(line));
                continue;
            }
            const line = lines.join(' ');
            if (hasQuote && attributed(line)) fold(node, end, line);
            return;
        }
    }, { once: true });
    """#
}
