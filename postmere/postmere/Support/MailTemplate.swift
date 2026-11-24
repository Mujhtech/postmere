import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MailTemplateHeaders: Equatable {
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var attachments: [MailAttachment] = []
}

struct MailTemplateDraft: Equatable {
    var headers = MailTemplateHeaders()
    var body = ""
    var bodyRTF: Data?

    var hasContent: Bool {
        [headers.to, headers.cc, headers.bcc, headers.subject, body].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } || !headers.attachments.isEmpty
    }
}

enum MailTemplateApplyMode: String, CaseIterable, Identifiable {
    case insert, append, replace
    var id: Self { self }
    var title: String {
        switch self {
        case .insert: "Insert at cursor"
        case .append: "Append"
        case .replace: "Replace"
        }
    }
}

/// Prepared once from the preview. Body edits go through NSTextView; field
/// snapshots let that same native Undo group restore recipients and attachments.
struct MailTemplateApplication {
    let templateID: UUID
    let title: String
    let mode: MailTemplateApplyMode
    let body: String
    let bodyRTF: Data?
    let beforeHeaders: MailTemplateHeaders
    let afterHeaders: MailTemplateHeaders

    var changesHeaders: Bool { beforeHeaders != afterHeaders }
    var attributedBody: NSAttributedString { MailTemplate.richBody(text: body, rtf: bodyRTF) }
}

enum MailTemplate {
    static func placeholderNames(in snippet: MailSnippet) -> [String] {
        let fields = [snippet.to, snippet.cc, snippet.bcc, snippet.subject, snippet.body].compactMap { $0 }
            + snippet.attachments.map(\.name)
        var result: [String] = []
        for field in fields {
            for name in SnippetPlaceholders.names(in: field) where !result.contains(name) { result.append(name) }
        }
        return result
    }

    static func prepare(_ snippet: MailSnippet, values: [String: String], draft: MailTemplateDraft,
                        mode: MailTemplateApplyMode) throws -> MailTemplateApplication {
        let missing = placeholderNames(in: snippet).filter { (values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard missing.isEmpty else { throw MailTemplateError.missingValues(missing) }
        if mode == .insert && snippet.isTemplate { throw MailTemplateError.requiresApplyMode }
        for attachment in snippet.attachments {
            guard let url = attachment.localURL, url.isFileURL,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw MailTemplateError.attachmentUnavailable(attachment.name)
            }
        }

        func expand(_ field: String?) -> String? { field.map { SnippetPlaceholders.expand($0, values: values) } }
        let to = expand(snippet.to)
        let cc = expand(snippet.cc)
        let bcc = expand(snippet.bcc)
        let subject = expand(snippet.subject)
        for (label, field) in [("To", to), ("Cc", cc), ("Bcc", bcc)] {
            guard let field else { continue }
            let invalid = MailAddressList(field).invalid
            guard invalid.isEmpty else { throw MailTemplateError.invalidRecipients(label, invalid) }
        }
        if let subject, subject.contains(where: { $0.isNewline }) { throw MailTemplateError.multilineSubject }

        let rich = SnippetPlaceholders.expand(richBody(text: snippet.body, rtf: snippet.bodyRTF), values: values)
        let expandedAttachments = snippet.attachments.map { attachment in
            var result = attachment
            result.name = SnippetPlaceholders.expand(attachment.name, values: values)
            return result
        }
        var headers = draft.headers
        switch mode {
        case .insert: break
        case .append:
            if let to { headers.to = mergeAddresses(headers.to, to) }
            if let cc { headers.cc = mergeAddresses(headers.cc, cc) }
            if let bcc { headers.bcc = mergeAddresses(headers.bcc, bcc) }
            if headers.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let subject { headers.subject = subject }
            let existingIDs = Set(headers.attachments.map(\.id))
            headers.attachments.append(contentsOf: expandedAttachments.filter { !existingIDs.contains($0.id) })
        case .replace:
            if let to { headers.to = to }
            if let cc { headers.cc = cc }
            if let bcc { headers.bcc = bcc }
            if let subject { headers.subject = subject }
            headers.attachments = expandedAttachments
        }
        return MailTemplateApplication(templateID: snippet.id, title: snippet.title, mode: mode,
                                       body: rich.string, bodyRTF: encodeRTF(rich),
                                       beforeHeaders: draft.headers, afterHeaders: headers)
    }

    static func richBody(text: String, rtf: Data?) -> NSAttributedString {
        if let rtf,
           let rich = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           rich.string == text { return rich }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: 14), ink = NSColor.labelColor
        #else
        let font = UIFont.systemFont(ofSize: 14), ink = UIColor.label
        #endif
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
    }

    static func encodeRTF(_ text: NSAttributedString) -> Data? {
        guard text.length > 0 else { return nil }
        return try? text.data(from: NSRange(location: 0, length: text.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func appendSeparator(after text: String, adding addition: String) -> String {
        guard !text.isEmpty, !addition.isEmpty else { return "" }
        if text.hasSuffix("\n\n") { return "" }
        return text.hasSuffix("\n") ? "\n" : "\n\n"
    }

    static func resultingBody(_ application: MailTemplateApplication, draft: MailTemplateDraft) -> NSAttributedString {
        guard application.mode == .append else { return application.attributedBody }
        let result = NSMutableAttributedString(attributedString: richBody(text: draft.body, rtf: draft.bodyRTF))
        result.append(richBody(text: appendSeparator(after: result.string, adding: application.body), rtf: nil))
        result.append(application.attributedBody)
        return result
    }

    private static func mergeAddresses(_ current: String, _ addition: String) -> String {
        guard !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return current }
        let currentList = MailAddressList(current)
        let additionList = MailAddressList(addition)
        var seen = Set(currentList.addresses.map { $0.lowercased() })
        let newAddresses = additionList.addresses.filter { seen.insert($0.lowercased()).inserted }
        guard !newAddresses.isEmpty else { return current }
        // Keep the existing display text (including names) exactly as written.
        return current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? addition : current + ", " + newAddresses.joined(separator: ", ")
    }
}

enum MailTemplateError: LocalizedError {
    case missingValues([String])
    case invalidRecipients(String, [String])
    case multilineSubject
    case requiresApplyMode
    case attachmentUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingValues(let values): "Fill in \(values.joined(separator: ", ")) before applying this template."
        case .invalidRecipients(let field, let addresses): "Check \(field): \(addresses.joined(separator: ", ")) is not a valid email address."
        case .multilineSubject: "The subject must fit on one line."
        case .requiresApplyMode: "Choose Append or Replace for a template with message fields or attachments."
        case .attachmentUnavailable(let name): "The saved file \(name) is unavailable. Edit the template and attach it again."
        }
    }
}

enum SnippetPlaceholders {
    private static let expression = try! NSRegularExpression(pattern: #"\{\{([^{}\r\n]+)\}\}"#)

    static func names(in text: String) -> [String] {
        let source = text as NSString
        var names: [String] = []
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names
    }

    static func expand(_ text: String, values: [String: String]) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let value = values[name], !value.isEmpty { result.replaceCharacters(in: match.range, with: value) }
        }
        return result as String
    }

    static func expand(_ text: NSAttributedString, values: [String: String]) -> NSAttributedString {
        let source = text.string as NSString
        let result = NSMutableAttributedString(attributedString: text)
        for match in expression.matches(in: text.string, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard let value = values[name], !value.isEmpty else { continue }
            let attributes = text.attributes(at: match.range.location, effectiveRange: nil)
            result.replaceCharacters(in: match.range, with: NSAttributedString(string: value, attributes: attributes))
        }
        return result
    }
}
