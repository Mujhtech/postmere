import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A message laid out for paper: who, to whom, when and the subject, then the body.
/// Remote images and styles are left out so printing never contacts the sender's
/// servers, as the reader does until images are allowed.
enum MailPrintDocument {
    static func html(for message: MailMessage) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var rows = [("From", "\(message.sender) <\(message.senderEmail)>"),
                    ("To", message.toRecipients.joined(separator: ", "))]
        if !message.ccRecipients.isEmpty { rows.append(("Cc", message.ccRecipients.joined(separator: ", "))) }
        rows.append(("Date", message.sentAt.formatted(date: .complete, time: .shortened)))
        let header = rows.map { "<tr><th>\($0.0)</th><td>\(escape($0.1))</td></tr>" }.joined()
        let body: String
        if let html = message.receivedHTML ?? message.bodyHTML, !html.isEmpty {
            body = withoutRemoteResources(html)
        } else {
            body = message.paragraphs.map { "<p>\(escape($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined()
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font: 11pt -apple-system, Helvetica, sans-serif; color: #111; margin: 0; }
        h1 { font: 600 17pt -apple-system, Helvetica, sans-serif; margin: 0 0 10pt; }
        table.envelope { border-collapse: collapse; margin-bottom: 14pt; font-size: 9.5pt; }
        table.envelope th { text-align: right; color: #666; font-weight: 500; padding: 1pt 8pt 1pt 0; vertical-align: top; }
        hr { border: 0; border-top: 0.5pt solid #bbb; margin: 0 0 14pt; }
        img, table { max-width: 100% !important; }
        </style></head><body>
        <h1>\(escape(message.displaySubject.isEmpty ? "No subject" : message.displaySubject))</h1>
        <table class="envelope">\(header)</table><hr>
        \(body)
        </body></html>
        """
    }

    /// Drops scripts, linked styles and anything loaded from the network.
    static func withoutRemoteResources(_ html: String) -> String {
        var result = html
        let patterns = [
            #"(?is)<script\b.*?</script>"#,
            #"(?is)<link\b[^>]*>"#,
            #"(?is)<(iframe|object|embed)\b.*?(</\1>|/?>)"#,
            #"(?i)\s(src|srcset|background)\s*=\s*("|')\s*(https?:)?//[^"']*\2"#,
            #"(?i)url\(\s*['"]?\s*(https?:)?//[^)]*\)"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    #if os(iOS)
    @MainActor static func present(_ message: MailMessage) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = message.displaySubject.isEmpty ? "Message" : message.displaySubject
        controller.printInfo = info
        let formatter = UIMarkupTextPrintFormatter(markupText: html(for: message))
        formatter.perPageContentInsets = UIEdgeInsets(top: 54, left: 54, bottom: 54, right: 54)
        controller.printFormatter = formatter
        controller.present(animated: true)
    }
    #else
    @MainActor static func present(_ message: MailMessage) {
        guard let data = html(for: message).data(using: .utf8),
              let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil) else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = message.displaySubject.isEmpty ? "Message" : message.displaySubject
        operation.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
    #endif
}
