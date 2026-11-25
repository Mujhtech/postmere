import SwiftUI

struct RichTextMessageBody: View {
    @Environment(\.postmereAccent) private var palette
    let rtf: Data?
    let paragraphs: [String]
    let fontSize: Double
    var readingFont = MailReadingFont.original
    var quoteContext: MailQuoteContext?

    @State private var rendered: RenderedBody?
    @State private var showsQuote = false

    private struct Source: Equatable, Sendable {
        let rtf: Data?
        let paragraphs: [String]
        let context: MailQuoteContext?
    }
    private struct RenderRequest: Equatable {
        let source: Source
        let font: MailReadingFont
        let size: Double
    }

    private enum TextBody {
        case formatted(AttributedString)
        case plain([String])
    }

    private struct RenderedBody {
        let reply: TextBody
        var quote: TextBody?
        var title = ""
    }

    var body: some View {
        let source = Source(rtf: rtf, paragraphs: paragraphs, context: quoteContext)
        Group {
            if let rendered {
                VStack(alignment: .leading, spacing: 8) {
                    content(rendered.reply)
                    if let quote = rendered.quote {
                        Button {
                            showsQuote.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showsQuote ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Text(showsQuote ? "Show less" : rendered.title)
                            }
                        }
                        .font(.callout)
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accentInk)
                        .accessibilityValue(showsQuote ? "Expanded" : "Collapsed")
                        if showsQuote { content(quote) }
                    }
                }
            } else if rtf == nil && quoteContext == nil {
                content(.plain(paragraphs))
            } else if let first = paragraphs.first(where: { !$0.isEmpty }) {
                Text(verbatim: String(first.prefix(600))).lineLimit(6)
            } else {
                ProgressView("Loading message…").controlSize(.small)
            }
        }
        .font(readingFont.font(size: fontSize))
        .lineSpacing(5)
        .tint(palette.accentInk)
        .onChange(of: source) {
            showsQuote = false
            rendered = nil
        }
        .task(id: RenderRequest(source: source, font: rtf == nil ? .original : readingFont, size: rtf == nil ? 14 : fontSize)) {
            guard rtf != nil || quoteContext != nil else { return }
            let result = await Self.prepare(source, font: readingFont, size: fontSize)
            guard !Task.isCancelled else { return }
            rendered = result
        }
    }

    @ViewBuilder private func content(_ body: TextBody) -> some View {
        switch body {
        case .formatted(let formatted):
            Text(formatted).fixedSize(horizontal: false, vertical: true)
        case .plain(let paragraphs):
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    Text(MailLinkDetector.attributed(paragraphs[index])).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @concurrent private static func prepare(_ source: Source, font: MailReadingFont, size: Double) async -> RenderedBody {
        if let rtf = source.rtf, !Task.isCancelled,
           let original = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           original.length > 0 {
            let formatted = NSMutableAttributedString(attributedString: font.format(original, size: size))
            MailLinkDetector.link(formatted)
            let rich: NSAttributedString = formatted
            let text = rich.string
            if let split = source.context?.plainQuote(in: text) {
                let end = text[..<split.start].lastIndex(where: { !$0.isNewline }).map { text.index(after: $0) } ?? text.startIndex
                let prefix = NSRange(text.startIndex..<end, in: text)
                let suffix = NSRange(split.start..<text.endIndex, in: text)
                return RenderedBody(reply: .formatted(AttributedString(rich.attributedSubstring(from: prefix))),
                                    quote: .formatted(AttributedString(rich.attributedSubstring(from: suffix))), title: split.title)
            }
            return RenderedBody(reply: .formatted(AttributedString(rich)))
        }

        guard !Task.isCancelled, let context = source.context else { return RenderedBody(reply: .plain(source.paragraphs)) }
        let text = source.paragraphs.joined(separator: "\n\n")
        guard let split = context.plainQuote(in: text) else { return RenderedBody(reply: .plain(source.paragraphs)) }
        var offset = text.utf8.distance(from: text.utf8.startIndex, to: split.start)
        for (index, paragraph) in source.paragraphs.enumerated() {
            let count = paragraph.utf8.count
            if offset <= count {
                let boundary = paragraph.utf8.index(paragraph.startIndex, offsetBy: offset)
                var prefix = Array(source.paragraphs.prefix(index))
                let before = paragraph[..<boundary].trimmingCharacters(in: .newlines)
                if !before.isEmpty { prefix.append(before) }
                let suffix = [String(paragraph[boundary...])] + source.paragraphs.dropFirst(index + 1)
                return RenderedBody(reply: .plain(prefix), quote: .plain(suffix), title: split.title)
            }
            offset -= count + 2
        }
        return RenderedBody(reply: .plain(source.paragraphs))
    }
}
