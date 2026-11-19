import AppKit
import SwiftUI

struct RichTextMessageBody: View {
    @Environment(\.postmereAccent) private var palette
    let rtf: Data?
    let paragraphs: [String]
    let fontSize: Double

    @State private var formatted: AttributedString?
    @State private var finishedDecoding = false

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
        .font(.system(size: fontSize))
        .lineSpacing(5)
        .task(id: rtf) {
            guard let rtf else {
                formatted = nil
                finishedDecoding = false
                return
            }
            finishedDecoding = false
            formatted = nil
            let result = await Self.decode(rtf)
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
                    Text(verbatim: paragraphs[index]).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @concurrent private static func decode(_ data: Data) async -> AttributedString? {
        guard !Task.isCancelled,
              let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                 documentAttributes: nil),
              text.length > 0 else { return nil }
        return AttributedString(text)
    }
}
