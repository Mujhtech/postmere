import AppKit
import SwiftUI

@MainActor
private final class TemplateCheckState {
    var text: String
    var rtf: Data?
    var headers: MailTemplateHeaders
    init(_ draft: MailTemplateDraft) { text = draft.body; rtf = draft.bodyRTF; headers = draft.headers }
}

@MainActor
private final class TemplateCheckRig {
    let window: NSWindow
    let editor: ComposeNativeTextView
    let formatting = ComposeTextFormatting()
    let state: TemplateCheckState
    let coordinator: ComposeBodyEditor.Coordinator

    init(draft: MailTemplateDraft) {
        state = TemplateCheckState(draft)
        let state = state
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        editor = ComposeNativeTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300), textContainer: container)
        window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        editor.isRichText = true
        editor.allowsUndo = true
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        window.contentView = editor
        let parent = ComposeBodyEditor(text: Binding(get: { state.text }, set: { state.text = $0 }),
                                       rtfData: Binding(get: { state.rtf }, set: { state.rtf = $0 }), formatting: formatting)
        coordinator = parent.makeCoordinator()
        editor.delegate = coordinator
        coordinator.attach(editor, formatting: formatting)
        coordinator.applyIncoming(to: editor)
        window.makeFirstResponder(editor)
        settle()
    }

    func apply(_ application: MailTemplateApplication) {
        let state = state
        precondition(formatting.applyTemplate(application, updateFields: { state.headers = $0 }))
        settle()
    }

    func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
}

@main
private struct TemplateChecks {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let oldID = UUID()
        let legacy = Data("{\"id\":\"\(oldID.uuidString)\",\"title\":\"Thanks\",\"body\":\"Thank you\"}".utf8)
        let decoded = try JSONDecoder().decode(MailSnippet.self, from: legacy)
        precondition(decoded.id == oldID && decoded.kind == .snippet && decoded.bodyRTF == nil)
        precondition(decoded.to == nil && decoded.cc == nil && decoded.bcc == nil && decoded.subject == nil && decoded.attachments.isEmpty)
        precondition(!decoded.isTemplate, "Legacy snippets must retain quick insertion")
        print("PASS: legacy snippet migration with all new fields defaulted")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Postmere-Template-Check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Notes.txt")
        let originalBytes = Data("Template attachment content".utf8)
        try originalBytes.write(to: source)
        let attachment = try MailAttachment.importFile(at: source, storageDirectory: temporary.appendingPathComponent("Owned", isDirectory: true))
        try FileManager.default.removeItem(at: source)
        let copiedBytes = try Data(contentsOf: attachment.localURL!)
        precondition(copiedBytes == originalBytes, "Template attachment copies must survive deleting the original")

        let body = NSMutableAttributedString(string: "Hello 👩🏽‍💻 {{name}} — {{name}}", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let nameRange = (body.string as NSString).range(of: "{{name}}")
        let bold = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 16), toHaveTrait: .boldFontMask)
        body.addAttributes([.font: bold, .link: URL(string: "https://example.com")!], range: nameRange)
        let snippet = MailSnippet(title: "Project update", body: body.string, kind: .template,
            bodyRTF: MailTemplate.encodeRTF(body), to: "{{email}}", cc: "", bcc: "{{private}}", subject: "Update: {{project}}", attachments: [attachment])
        precondition(MailTemplate.placeholderNames(in: snippet) == ["email", "private", "project", "name"])
        let values = ["email": "ada@example.com", "private": "review@example.com", "project": "Postmere", "name": "$1\\Ada"]
        let originalHeaders = MailTemplateHeaders(to: "Existing <existing@example.com>", cc: "copy@example.com", bcc: "", subject: "Keep this subject",
                                                  attachments: [MailAttachment(name: "old.pdf", detail: "PDF", localURL: nil)])
        let draft = MailTemplateDraft(headers: originalHeaders, body: "Original body")
        let replacement = try MailTemplate.prepare(snippet, values: values, draft: draft, mode: .replace)
        precondition(replacement.body == "Hello 👩🏽‍💻 $1\\Ada — $1\\Ada", "Unicode placeholders and replacement metacharacters must be literal")
        let expanded = replacement.attributedBody
        let expandedRange = (expanded.string as NSString).range(of: "$1\\Ada")
        let expandedFont = expanded.attribute(.font, at: expandedRange.location, effectiveRange: nil) as! NSFont
        precondition(NSFontManager.shared.traits(of: expandedFont).contains(.boldFontMask), "Placeholder expansion must retain rich style")
        precondition(expanded.attribute(.link, at: expandedRange.location, effectiveRange: nil) != nil, "Placeholder expansion must retain links")
        precondition(replacement.afterHeaders.to == "ada@example.com" && replacement.afterHeaders.cc.isEmpty)
        precondition(replacement.afterHeaders.bcc == "review@example.com" && replacement.afterHeaders.subject == "Update: Postmere")
        precondition(replacement.afterHeaders.attachments == [attachment])
        let roundTrip = try JSONDecoder().decode(MailSnippet.self, from: JSONEncoder().encode(snippet))
        precondition(roundTrip == snippet, "Rich templates and attachment URLs must survive Codable persistence")
        print("PASS: rich Unicode placeholders across headers/body, links, durable files, and Codable round trip")

        let appended = try MailTemplate.prepare(snippet, values: values, draft: draft, mode: .append)
        precondition(appended.afterHeaders.to == "Existing <existing@example.com>, ada@example.com")
        precondition(appended.afterHeaders.cc == "copy@example.com", "Append must not clear fields")
        precondition(appended.afterHeaders.subject == "Keep this subject", "Append must preserve a filled subject")
        precondition(appended.afterHeaders.attachments.count == 2)
        precondition(MailTemplate.resultingBody(appended, draft: draft).string == draft.body + "\n\n" + replacement.body)
        let duplicateDraft = MailTemplateDraft(headers: MailTemplateHeaders(to: "ADA@example.com", attachments: [attachment]), body: "")
        let deduplicated = try MailTemplate.prepare(snippet, values: values, draft: duplicateDraft, mode: .append)
        precondition(deduplicated.afterHeaders.to == "ADA@example.com" && deduplicated.afterHeaders.attachments.count == 1)
        let noHeaders = MailSnippet(title: "Body only", body: "New text", kind: .template)
        let untouched = try MailTemplate.prepare(noHeaders, values: [:], draft: draft, mode: .replace)
        precondition(untouched.afterHeaders.to == draft.headers.to && untouched.afterHeaders.subject == draft.headers.subject,
                     "Omitted template fields must not overwrite draft headers")
        print("PASS: append/replace semantics, recipient and file deduplication, omitted versus empty fields")

        do {
            _ = try MailTemplate.prepare(snippet, values: [:], draft: draft, mode: .replace)
            preconditionFailure("Unfilled placeholders must block apply")
        } catch MailTemplateError.missingValues { }
        do {
            var invalid = values; invalid["email"] = "not an email"
            _ = try MailTemplate.prepare(snippet, values: invalid, draft: draft, mode: .replace)
            preconditionFailure("Invalid template recipients must block apply")
        } catch MailTemplateError.invalidRecipients { }
        do {
            var injected = values; injected["project"] = "Postmere\r\nBcc: attacker@example.com"
            _ = try MailTemplate.prepare(snippet, values: injected, draft: draft, mode: .replace)
            preconditionFailure("Subject header line breaks must block apply")
        } catch MailTemplateError.multilineSubject { }
        do {
            _ = try MailTemplate.prepare(snippet, values: values, draft: draft, mode: .insert)
            preconditionFailure("Full templates must require append/replace")
        } catch MailTemplateError.requiresApplyMode { }
        do {
            let unavailable = MailSnippet(title: "Missing file", body: "See attachment", kind: .template,
                                          attachments: [MailAttachment(name: "missing.pdf", detail: "PDF", localURL: nil)])
            _ = try MailTemplate.prepare(unavailable, values: [:], draft: draft, mode: .append)
            preconditionFailure("Unavailable saved attachments must block apply")
        } catch MailTemplateError.attachmentUnavailable { }
        precondition(MailTemplate.richBody(text: "Updated plain text", rtf: snippet.bodyRTF).string == "Updated plain text", "Stale RTF must never restore outdated template text")
        print("PASS: missing/invalid placeholders, subject injection prevention, explicit mode, and stale RTF fallback")

        for application in [replacement, appended] {
            let rig = TemplateCheckRig(draft: draft)
            rig.apply(application)
            let expected = application.mode == .replace ? application.body : draft.body + "\n\n" + application.body
            precondition(rig.editor.string == expected && rig.state.text == expected)
            precondition(rig.state.headers == application.afterHeaders)
            precondition(rig.state.rtf != nil)
            let insertedRange = (rig.editor.string as NSString).range(of: "$1\\Ada")
            let font = rig.editor.attributedString().attribute(.font, at: insertedRange.location, effectiveRange: nil) as! NSFont
            precondition(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            rig.editor.undoManager!.undo(); rig.settle()
            precondition(rig.editor.string == draft.body && rig.state.headers == draft.headers,
                         "One native Undo must restore body, subject, recipients, and attachments")
            rig.editor.undoManager!.redo(); rig.settle()
            precondition(rig.editor.string == expected && rig.state.headers == application.afterHeaders,
                         "One native Redo must restore the complete template operation")
        }
        let quickRig = TemplateCheckRig(draft: draft)
        quickRig.editor.setSelectedRange(NSRange(location: 0, length: 8))
        let quick = MailSnippet(title: "Rich insert", body: body.string, bodyRTF: MailTemplate.encodeRTF(body))
        let quickApplication = try MailTemplate.prepare(quick, values: values, draft: draft, mode: .insert)
        quickRig.apply(quickApplication)
        precondition(quickRig.editor.string == quickApplication.body + " body" && quickRig.state.headers == draft.headers)
        quickRig.editor.undoManager!.undo(); quickRig.settle()
        precondition(quickRig.editor.string == "Original body", "Rich quick insertion must retain selection-aware native Undo")
        print("PASS: native grouped Undo/Redo for rich append/replace with all fields, and rich quick insertion")
    }
}
