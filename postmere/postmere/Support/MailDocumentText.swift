import Foundation
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Plain text from a PDF or text file, read on the device.
enum MailDocumentText {
    static func canSummarize(_ attachment: MailAttachment) -> Bool {
        let name = attachment.name.lowercased()
        return ["pdf", "txt", "md", "csv", "html", "htm", "rtf", "json"].contains { name.hasSuffix("." + $0) }
    }

    @concurrent static func extract(from url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return nil }
            var text = ""
            for index in 0..<min(document.pageCount, 60) {
                text += (document.page(at: index)?.string ?? "") + "\n"
                if text.count > 60_000 { break }
            }
            return String(text.prefix(60_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ext == "rtf" || ext == "html" || ext == "htm" {
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .html
            guard let data = try? Data(contentsOf: url),
                  let text = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil) else { return nil }
            return String(text.string.prefix(60_000))
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(decoding: data.prefix(240_000), as: UTF8.self).prefix(60_000).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
