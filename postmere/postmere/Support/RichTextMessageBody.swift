import AppKit
import SwiftUI

struct RichTextMessageBody: View {
    let rtf: Data?
    let paragraphs: [String]
    let fontSize: Double

    @State private var formatted: AttributedString?
    @State private var finishedDecoding = false

    var body: some View {
        Group {
            if let formatted {
                Text(formatted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if rtf != nil && !finishedDecoding {
                if let first = paragraphs.first(where: { !$0.isEmpty }) {
                    Text(verbatim: String(first.prefix(600))).lineLimit(6)
                } else {
                    ProgressView("Loading message…").controlSize(.small)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        Text(verbatim: paragraphs[index]).fixedSize(horizontal: false, vertical: true)
                    }
                }
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
            formatted = result
            finishedDecoding = true
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
