@MainActor
final class ComposeCheckDraft {
    var text = ""
    var rtf: Data?
}

@MainActor
private final class ComposeCheckRig {
    let window: NSWindow
    let editor: ComposeNativeTextView
    let formatting = ComposeTextFormatting()
    let draft = ComposeCheckDraft()
    let coordinator: ComposeBodyEditor.Coordinator

    init() {
        let draft = self.draft
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        editor = ComposeNativeTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 400), textContainer: container)
        window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        editor.isRichText = true
        editor.allowsUndo = true
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        window.contentView = editor
        let parent = ComposeBodyEditor(text: Binding(get: { draft.text }, set: { draft.text = $0 }), rtfData: Binding(get: { draft.rtf }, set: { draft.rtf = $0 }), formatting: formatting)
        coordinator = parent.makeCoordinator()
        editor.delegate = coordinator
        coordinator.attach(editor, formatting: formatting)
        coordinator.applyIncoming(to: editor)
        window.makeFirstResponder(editor)
        settle()
    }

    func type(_ text: String) {
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            settle()
        }
    }

    func newline() { editor.insertNewline(nil); settle() }
    func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.003)) }
    func font(at location: Int) -> NSFont { editor.textStorage!.attribute(.font, at: location, effectiveRange: nil) as! NSFont }
    func paragraph(at location: Int) -> NSParagraphStyle { editor.textStorage!.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle ?? .default }
}

@MainActor
func runComposerFeatureChecks() throws {
    _ = NSApplication.shared
    do {
        let rig = ComposeCheckRig()
        rig.type("Original **bold** reply")
        let originalText = rig.editor.string
        rig.formatting.replaceBodyWithSuggestion("A clearer proposed reply.")
        rig.settle()
        precondition(rig.draft.text == "A clearer proposed reply.", "AI replacement must publish the complete editable draft")
        rig.editor.undoManager!.undo(); rig.settle()
        precondition(rig.editor.string == originalText, "One Undo must restore the full pre-AI draft")
        precondition(NSFontManager.shared.traits(of: rig.font(at: 9)).contains(.boldFontMask), "AI Undo must preserve the original rich formatting")
        rig.editor.undoManager!.redo(); rig.settle()
        precondition(rig.editor.string == "A clearer proposed reply.", "AI replacement must support native Redo")
        print("PASS: AI draft replacement is editable and preserves the original rich body through Undo/Redo")
    }
    do {
        let rig = ComposeCheckRig()
        rig.type("Hello **bold**")
        precondition(rig.editor.string == "Hello bold", "Bold must remove the Markdown delimiters")
        precondition(NSFontManager.shared.traits(of: rig.font(at: 6)).contains(.boldFontMask), "Bold style must be applied")
        precondition(!rig.formatting.isBold, "Following text must retain the pre-Markdown typing style")
        precondition(rig.editor.selectedRange() == NSRange(location: 10, length: 0), "Caret must follow the substituted text")
        precondition(rig.draft.text == "Hello bold" && rig.draft.rtf != nil, "Markdown must publish text and RTF")
        let rich = try NSAttributedString(data: rig.draft.rtf!, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        precondition(NSFontManager.shared.traits(of: rich.attribute(.font, at: 6, effectiveRange: nil) as! NSFont).contains(.boldFontMask), "RTF must preserve Markdown formatting")
        rig.editor.undoManager!.undo(); rig.settle()
        precondition(rig.editor.string == "Hello **bold**", "One Undo must restore literal Markdown, including its closing marker")
        rig.editor.undoManager!.redo(); rig.settle()
        precondition(rig.editor.string == "Hello bold", "Redo must restore substitution")
        print("PASS: reversible bold, caret, typing style, and RTF")
    }
    for input in ["*italic*", "_italic_", "***both***", "`code`", "👩🏽‍💻 **café**"] {
        let rig = ComposeCheckRig(); rig.type(input)
        precondition(rig.editor.string != input, "Inline substitution failed: \(input)")
        precondition(rig.editor.selectedRange().location == rig.editor.string.utf16.count, "Unicode caret must remain valid")
        rig.editor.undoManager!.undo(); rig.settle()
        precondition(rig.editor.string == input, "Inline undo must restore exact Unicode source: \(input)")
    }
    for input in ["snake_case_", "\\**literal**", "** padded **"] {
        let rig = ComposeCheckRig(); rig.type(input)
        precondition(rig.editor.string == input, "Invalid or escaped Markdown must stay literal: \(input)")
    }
    do {
        let rig = ComposeCheckRig(); rig.editor.markdownEnabled = false; rig.type("**literal**")
        precondition(rig.editor.string == "**literal**", "Markdown preference must disable substitutions")
        rig.editor.markdownEnabled = true
        rig.editor.insertText(" **pasted**", replacementRange: rig.editor.selectedRange())
        precondition(rig.editor.string.hasSuffix(" **pasted**"), "Pasting must not unexpectedly reformat text")
        print("PASS: inline Markdown, Unicode, escape handling, preference, and paste")
    }
    do {
        let rig = ComposeCheckRig(); rig.type("# Title"); rig.newline(); rig.type("Body")
        precondition(rig.editor.string == "Title\nBody", "Heading text must be preserved")
        precondition(rig.paragraph(at: 0).headerLevel == 1 && rig.font(at: 0).pointSize == 28, "Heading semantics must remain on the heading")
        precondition(rig.paragraph(at: 6).headerLevel == 0 && rig.font(at: 6).pointSize == 14, "Return must end heading formatting")
    }
    do {
        let rig = ComposeCheckRig(); rig.type("> Quote"); rig.newline(); rig.newline(); rig.type("Body")
        precondition(rig.editor.string == "Quote\nBody", "A blank Return must end the quote without losing text")
        precondition(rig.paragraph(at: 0).headIndent == 20 && rig.paragraph(at: 6).headIndent == 0, "Quote indentation must end")
    }
    do {
        let rig = ComposeCheckRig(); rig.type("* First"); rig.newline(); rig.type("Second"); rig.newline(); rig.newline(); rig.type("Body")
        precondition(rig.editor.string == "•\tFirst\n•\tSecond\nBody", "Bullets must continue and a blank Return must end them")
        precondition(rig.paragraph(at: rig.editor.string.utf16.count - 1).headIndent == 0, "Exited lists must restore paragraph indentation")
        let numbered = ComposeCheckRig(); numbered.type("1. One"); numbered.newline(); numbered.type("Two")
        precondition(numbered.editor.string == "1.\tOne\n2.\tTwo", "Numbered lists must increment")
        print("PASS: headings, quotes, and bullet/numbered continuation")
    }
    do {
        let rig = ComposeCheckRig(); rig.type("```"); rig.type("**literal**"); rig.newline(); rig.type("```"); rig.type("Body")
        precondition(rig.editor.string == "**literal**\nBody", "Fenced code must stay literal and allow closing fence")
        precondition(rig.font(at: 0).isFixedPitch && !rig.font(at: 12).isFixedPitch, "Fenced code font must end at the closing fence")
    }
    do {
        let rig = ComposeCheckRig(); rig.type("Hello world")
        rig.editor.setSelectedRange(NSRange(location: 6, length: 5))
        rig.formatting.insertSnippet("Ada\nThank you")
        rig.settle()
        precondition(rig.editor.string == "Hello Ada\nThank you", "Snippets must replace only the body selection")
        rig.editor.undoManager!.undo(); rig.settle()
        precondition(rig.editor.string == "Hello world", "Snippet insertion must use native undo")
        let text = "👋 {{ name }}, {{project}} — {{name}}"
        precondition(SnippetPlaceholders.names(in: text) == ["name", "project"], "Placeholder fields must be unique and ordered")
        precondition(SnippetPlaceholders.expand(text, values: ["name": "$1\\Ada", "project": "Postmere"]) == "👋 $1\\Ada, Postmere — $1\\Ada", "Placeholder values must be inserted literally")
        print("PASS: fenced code and attributed-safe snippet insertion/placeholders")
    }
    do {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pdf = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("postmere/postmere/Resources/Fieldnotes-direction.pdf"))
        let item = NSPasteboardItem(); item.setData(pdf, forType: .pdf); item.setData(Data([1,2,3]), forType: .tiff)
        pasteboard.writeObjects([item])
        let capture = ComposeContinuityCapture()
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("Postmere-Capture-Check-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: owned) }
        var temporaryCapture: URL?
        capture.onReceive = { urls in
            precondition(urls.count == 1 && urls[0].pathExtension == "pdf", "PDF must take precedence over image representations")
            temporaryCapture = urls[0]
            try FileManager.default.copyItem(at: urls[0], to: owned)
        }
        precondition(capture.accepts(.pdf) && capture.accepts(.png) && !capture.accepts(.string), "Capture must advertise only supported image/PDF types")
        precondition(capture.readSelection(from: pasteboard), "Native pasteboard capture must reach the attachment callback")
        let savedPDF = try Data(contentsOf: owned)
        precondition(savedPDF == pdf, "Scanned PDF data must remain unchanged")
        precondition(!FileManager.default.fileExists(atPath: temporaryCapture!.path), "Temporary capture files must be removed after import")
        print("PASS: native capture pasteboard pipeline, PDF preservation, and temporary-file cleanup")
    }
}

@main
private struct ComposerChecks {
    @MainActor static func main() throws { try runComposerFeatureChecks() }
}
