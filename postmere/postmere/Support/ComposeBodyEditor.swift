import AppKit
import Observation
import SwiftUI

struct MailFormattingButton: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PostmereIcon(symbol, size: 14)
                .frame(width: 26, height: 24)
                .foregroundStyle(active ? PostmereTheme.accentInk : PostmereTheme.icon)
                .background(active ? PostmereTheme.accentInk.opacity(0.12) : .clear, in: .rect(cornerRadius: 4))
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(active ? "On" : "Off")
    }
}

/// The composer toolbar talks to the native text system through this window-local object.
@MainActor
@Observable
final class ComposeTextFormatting {
    private(set) var fontSize: CGFloat = 14
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderlined = false
    private(set) var textColor: NSColor = .labelColor
    private(set) var alignment: NSTextAlignment = .left
    private(set) var canUndo = false

    @ObservationIgnored private weak var editor: NSTextView?
    @ObservationIgnored private var didFormat: (() -> Void)?
    @ObservationIgnored private var wantsFocus = false
    @ObservationIgnored private var colorPanelTarget: ComposeColorPanelTarget?

    func toggleBold() {
        refreshSelection()
        let removeTrait = isBold
        changeFont { font in
            removeTrait
                ? NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
                : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
    }

    func toggleItalic() {
        refreshSelection()
        let removeTrait = isItalic
        changeFont { font in
            removeTrait
                ? NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
                : NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
    }

    func toggleUnderline() {
        refreshSelection()
        let shouldUnderline = !isUnderlined
        performFormatting { editor in
            editor.changeAttributes(ComposeAttributeConversion { attributes in
                var result = attributes
                result[.underlineStyle] = shouldUnderline ? NSUnderlineStyle.single.rawValue : 0
                return result
            })
        }
    }

    func setFontSize(_ size: CGFloat) {
        guard size.isFinite else { return }
        let size = min(max(size, 8), 72)
        changeFont { NSFontManager.shared.convert($0, toSize: size) }
    }

    func setTextColor(_ color: NSColor) {
        performFormatting { editor in
            editor.changeAttributes(ComposeAttributeConversion { attributes in
                var result = attributes
                result[.foregroundColor] = color
                return result
            })
        }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        performFormatting { editor in
            switch alignment {
            case .center: editor.alignCenter(nil)
            case .right: editor.alignRight(nil)
            case .justified: editor.alignJustified(nil)
            default: editor.alignLeft(nil)
            }
        }
    }

    func undo() {
        guard let editor, let manager = activeUndoManager, manager.canUndo else { return }
        (editor.window?.firstResponder as? NSTextView)?.breakUndoCoalescing()
        manager.undo()
        refreshSelection()
        didFormat?()
    }

    func showCharacterPalette() {
        focus()
        NSApp.orderFrontCharacterPalette(nil)
    }

    func showListPanel() {
        focus()
        editor?.orderFrontListPanel(nil)
    }

    func showColorPanel() {
        focus()
        refreshSelection()
        let target = colorPanelTarget ?? ComposeColorPanelTarget(formatting: self)
        colorPanelTarget = target
        target.show(color: textColor)
    }

    /// Inserts without replacing surrounding rich text or borrowing a sheet's selection.
    func insertText(_ text: String) {
        guard let editor, !text.isEmpty else { return }
        let selection = editor.selectedRange()
        let attributes = editor.typingAttributes
        editor.window?.makeFirstResponder(editor)
        if editor.selectedRange() != selection { editor.setSelectedRange(selection) }
        editor.breakUndoCoalescing()
        editor.insertText(NSAttributedString(string: text, attributes: attributes), replacementRange: selection)
        editor.breakUndoCoalescing()
        editor.scrollRangeToVisible(editor.selectedRange())
        refreshSelection()
        didFormat?()
    }

    func insertSnippet(_ text: String) { insertText(text) }

    func replaceBodyWithSuggestion(_ text: String) {
        guard let editor else { return }
        editor.window?.makeFirstResponder(editor)
        editor.breakUndoCoalescing()
        editor.insertText(MailTemplate.richBody(text: text, rtf: nil), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.undoManager?.setActionName("Use AI Draft")
        editor.breakUndoCoalescing()
        refreshSelection()
        didFormat?()
    }

    /// Applies the previewed content as one native Undo operation. The callback
    /// must change only headers/attachments, never the body or its RTF binding.
    @discardableResult
    func applyTemplate(_ application: MailTemplateApplication,
                       updateFields: @escaping (MailTemplateHeaders) -> Void) -> Bool {
        guard let editor else { return false }
        let selection = editor.selectedRange()
        editor.window?.makeFirstResponder(editor)
        if editor.selectedRange() != selection { editor.setSelectedRange(selection) }
        editor.breakUndoCoalescing()
        let manager = editor.undoManager
        if manager?.groupsByEvent == true, manager?.groupingLevel == 1 { manager?.endUndoGrouping() }
        manager?.beginUndoGrouping()

        if application.changesHeaders {
            updateFields(application.afterHeaders)
            if let manager {
                registerTemplateFieldUndo(before: application.beforeHeaders, after: application.afterHeaders,
                                          manager: manager, updateFields: updateFields)
            }
        }

        let content = NSMutableAttributedString(attributedString: application.attributedBody)
        let range: NSRange
        switch application.mode {
        case .insert:
            range = selection
        case .append:
            range = NSRange(location: editor.string.utf16.count, length: 0)
            let separator = MailTemplate.appendSeparator(after: editor.string, adding: content.string)
            if !separator.isEmpty { content.insert(MailTemplate.richBody(text: separator, rtf: nil), at: 0) }
        case .replace:
            range = NSRange(location: 0, length: editor.string.utf16.count)
        }
        if content.length > 0 || range.length > 0 {
            editor.insertText(content, replacementRange: range)
        }
        manager?.setActionName(application.mode == .insert ? "Insert Snippet" : "Apply Template")
        manager?.endUndoGrouping()
        editor.breakUndoCoalescing()
        editor.scrollRangeToVisible(editor.selectedRange())
        refreshSelection()
        didFormat?()
        return true
    }

    private func registerTemplateFieldUndo(before: MailTemplateHeaders, after: MailTemplateHeaders,
                                           manager: UndoManager,
                                           updateFields: @escaping (MailTemplateHeaders) -> Void) {
        manager.registerUndo(withTarget: self) { [weak manager] formatting in
            guard let manager else { return }
            formatting.registerTemplateFieldUndo(before: after, after: before, manager: manager, updateFields: updateFields)
            updateFields(before)
        }
    }

    /// May be requested before the representable is attached to its window.
    func focus() {
        wantsFocus = true
        fulfillFocusRequest()
    }

    fileprivate func attach(_ editor: NSTextView, didFormat: @escaping () -> Void) {
        self.editor = editor
        self.didFormat = didFormat
    }

    fileprivate func detach(_ editor: NSTextView) {
        guard self.editor === editor else { return }
        self.editor = nil
        didFormat = nil
        colorPanelTarget?.detach()
        colorPanelTarget = nil
        canUndo = false
    }

    fileprivate func fulfillFocusRequest() {
        guard wantsFocus, let editor, let window = editor.window else { return }
        wantsFocus = false
        window.makeFirstResponder(editor)
    }

    fileprivate func refreshSelection() {
        guard let editor else { return }
        var attributes: [[NSAttributedString.Key: Any]] = []
        if let storage = editor.textStorage {
            for value in editor.selectedRanges where value.rangeValue.length > 0 {
                let range = NSIntersectionRange(value.rangeValue, NSRange(location: 0, length: storage.length))
                storage.enumerateAttributes(in: range) { run, _, _ in attributes.append(run) }
            }
        }
        if attributes.isEmpty { attributes = [editor.typingAttributes] }
        let fonts = attributes.map { $0[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14) }
        fontSize = fonts.first?.pointSize ?? 14
        isBold = fonts.allSatisfy { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) }
        isItalic = fonts.allSatisfy { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) }
        isUnderlined = attributes.allSatisfy { ($0[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0 }
        textColor = attributes.first?[.foregroundColor] as? NSColor ?? .labelColor
        let paragraph = attributes.first?[.paragraphStyle] as? NSParagraphStyle
        let paragraphAlignment = paragraph?.alignment ?? .natural
        alignment = paragraphAlignment == .natural
            ? (paragraph?.baseWritingDirection == .rightToLeft ? .right : .left)
            : paragraphAlignment
        canUndo = activeUndoManager?.canUndo ?? false
    }

    private var activeUndoManager: UndoManager? {
        editor?.window?.firstResponder?.undoManager ?? editor?.undoManager
    }

    private func changeFont(_ transform: @escaping (NSFont) -> NSFont) {
        performFormatting { editor in
            editor.changeAttributes(ComposeAttributeConversion { attributes in
                var result = attributes
                result[.font] = transform(attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14))
                return result
            })
        }
    }

    private func performFormatting(_ change: (NSTextView) -> Void) {
        guard let editor else { return }
        let ranges = editor.selectedRanges
        let typingAttributes = editor.typingAttributes
        editor.window?.makeFirstResponder(editor)
        if editor.selectedRanges != ranges { editor.selectedRanges = ranges }
        if ranges.allSatisfy({ $0.rangeValue.length == 0 }) {
            editor.typingAttributes = typingAttributes
        }
        editor.breakUndoCoalescing()
        change(editor)
        // Assigning even an unchanged selection resets the insertion-point style.
        if editor.selectedRanges != ranges {
            let formattedTypingAttributes = editor.typingAttributes
            editor.selectedRanges = ranges
            editor.typingAttributes = formattedTypingAttributes
        }
        refreshSelection()
        didFormat?()
    }
}

/// Let NSTextView perform attribute changes, preserving its native undo behavior.
private final class ComposeAttributeConversion: NSObject {
    let transform: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]

    init(transform: @escaping ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        self.transform = transform
    }

    @objc func convertAttributes(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        transform(attributes)
    }
}

private final class ComposeColorPanelTarget: NSObject {
    private static weak var activeTarget: ComposeColorPanelTarget?
    private weak var formatting: ComposeTextFormatting?

    init(formatting: ComposeTextFormatting) { self.formatting = formatting }

    func show(color: NSColor) {
        let panel = NSColorPanel.shared
        Self.activeTarget = self
        panel.setTarget(self)
        panel.setAction(#selector(changeColor(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.color = color
        panel.orderFront(nil)
    }

    func detach() {
        guard Self.activeTarget === self else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        Self.activeTarget = nil
        formatting = nil
    }

    @objc private func changeColor(_ sender: NSColorPanel) {
        formatting?.setTextColor(sender.color)
    }
}

struct ComposeBodyEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
    let formatting: ComposeTextFormatting
    var fieldLabel = "Message"
    var markdownEnabled = true
    var onCaptureAttachments: (([URL]) throws -> Void)?
    var onCaptureError: ((Error) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let editor = ComposeNativeTextView(frame: .zero, textContainer: container)
        editor.markdownEnabled = markdownEnabled
        editor.continuityCapture.onReceive = onCaptureAttachments
        editor.continuityCapture.onError = onCaptureError
        editor.isRichText = true
        editor.importsGraphics = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.usesFontPanel = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.drawsBackground = false
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 24, height: 20)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.typingAttributes = Self.defaultAttributes
        editor.setAccessibilityLabel(fieldLabel)
        editor.delegate = context.coordinator
        editor.didAttachToWindow = { [weak formatting] in formatting?.fulfillFocusRequest() }
        scrollView.documentView = editor
        context.coordinator.attach(editor, formatting: formatting)
        context.coordinator.applyIncoming(to: editor)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if editor.accessibilityLabel() != fieldLabel { editor.setAccessibilityLabel(fieldLabel) }
        (editor as? ComposeNativeTextView)?.markdownEnabled = markdownEnabled
        (editor as? ComposeNativeTextView)?.continuityCapture.onReceive = onCaptureAttachments
        (editor as? ComposeNativeTextView)?.continuityCapture.onError = onCaptureError
        context.coordinator.attach(editor, formatting: formatting)
        context.coordinator.applyIncoming(to: editor)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let editor = scrollView.documentView as? NSTextView else { return }
        coordinator.formatting?.detach(editor)
        (editor as? ComposeNativeTextView)?.continuityCapture.onReceive = nil
        (editor as? ComposeNativeTextView)?.continuityCapture.onError = nil
        editor.delegate = nil
    }

    private static var defaultAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeBodyEditor
        weak var formatting: ComposeTextFormatting?
        private weak var editor: NSTextView?
        private var lastText: String?
        private var lastRTF: Data?
        private var hasAppliedContent = false
        private var isApplyingContent = false

        init(parent: ComposeBodyEditor) {
            self.parent = parent
            super.init()
            for name in [Notification.Name.NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoHistoryChanged(_:)), name: name, object: nil)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func attach(_ editor: NSTextView, formatting: ComposeTextFormatting) {
            if self.formatting !== formatting { self.formatting?.detach(editor) }
            self.editor = editor
            self.formatting = formatting
            formatting.attach(editor) { [weak self, weak editor] in
                if let editor { self?.publish(editor) }
            }
        }

        func applyIncoming(to editor: NSTextView) {
            let text = parent.text
            let rtf = parent.rtfData
            guard !hasAppliedContent || text != lastText || rtf != lastRTF else { return }
            hasAppliedContent = true
            lastText = text
            lastRTF = rtf

            let content: NSAttributedString
            if let rtf,
               let rich = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               rich.string == text {
                content = rich
            } else {
                content = NSAttributedString(string: text, attributes: ComposeBodyEditor.defaultAttributes)
            }
            guard !editor.attributedString().isEqual(to: content) else {
                refreshAfterUpdate(editor)
                return
            }

            isApplyingContent = true
            let selections = editor.selectedRanges.map { value in
                let location = min(value.rangeValue.location, content.length)
                let length = min(value.rangeValue.length, content.length - location)
                return NSValue(range: NSRange(location: location, length: length))
            }
            editor.textStorage?.setAttributedString(content)
            editor.selectedRanges = selections
            if content.length == 0 { editor.typingAttributes = ComposeBodyEditor.defaultAttributes }
            editor.undoManager?.removeAllActions()
            isApplyingContent = false
            refreshAfterUpdate(editor)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingContent, let editor = notification.object as? NSTextView else { return }
            publish(editor)
            formatting?.refreshSelection()
            refreshAfterUpdate(editor)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingContent else { return }
            formatting?.refreshSelection()
        }

        func textViewDidChangeTypingAttributes(_ notification: Notification) {
            guard !isApplyingContent else { return }
            formatting?.refreshSelection()
        }

        @objc private func undoHistoryChanged(_ notification: Notification) {
            guard let editor,
                  notification.object as AnyObject? === editor.undoManager
                    || notification.object as AnyObject? === editor.window?.firstResponder?.undoManager else { return }
            refreshAfterUpdate(editor)
        }

        private func publish(_ editor: NSTextView) {
            guard !isApplyingContent else { return }
            let text = editor.string
            let rtf = text.isEmpty ? nil : try? editor.attributedString().data(
                from: NSRange(location: 0, length: editor.textStorage?.length ?? 0),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            // Remember our own publication before SwiftUI echoes the bindings back.
            hasAppliedContent = true
            lastText = text
            lastRTF = rtf
            if parent.text != text { parent.text = text }
            if parent.rtfData != rtf { parent.rtfData = rtf }
        }

        private func refreshAfterUpdate(_ editor: NSTextView) {
            DispatchQueue.main.async { [weak self, weak editor] in
                guard self != nil, editor != nil else { return }
                self?.formatting?.refreshSelection()
                self?.formatting?.fulfillFocusRequest()
            }
        }
    }
}

private final class ComposeNativeTextView: NSTextView {
    var didAttachToWindow: (() -> Void)?
    var markdownEnabled = true
    let continuityCapture = ComposeContinuityCapture()

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, continuityCapture.accepts(returnType) { return continuityCapture }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let typedText = insertString as? String
        let shouldSubstitute = markdownEnabled && !hasMarkedText()
            && typedText?.count == 1 && undoManager?.isUndoing != true && undoManager?.isRedoing != true
        super.insertText(insertString, replacementRange: replacementRange)
        guard shouldSubstitute, !hasMarkedText(), let typedText,
              let replacement = MarkdownSubstitutions.replacement(
                in: attributedString(), selection: selectedRange(), insertedText: typedText, typingAttributes: typingAttributes
              ) else { return }
        applyMarkdownReplacement(replacement, separatesTyping: true)
    }

    override func insertNewline(_ sender: Any?) {
        guard markdownEnabled, !hasMarkedText(),
              let replacement = MarkdownSubstitutions.newlineReplacement(
                in: attributedString(), selection: selectedRange(), typingAttributes: typingAttributes
              ) else {
            super.insertNewline(sender)
            return
        }
        applyMarkdownReplacement(replacement, separatesTyping: false)
    }

    private func applyMarkdownReplacement(_ replacement: MarkdownTextReplacement, separatesTyping: Bool) {
        breakUndoCoalescing()
        // A separate undo step restores the literal Markdown, including its closing marker.
        if separatesTyping, let manager = undoManager {
            guard manager.groupingLevel <= 1 else { return }
            if manager.groupsByEvent, manager.groupingLevel == 1 { manager.endUndoGrouping() }
        }
        if replacement.range.length == 0 && replacement.content.length == 0 {
            changeTypingAttributesUndoably(replacement.typingAttributes)
        } else {
            super.insertText(replacement.content, replacementRange: replacement.range)
            typingAttributes = replacement.typingAttributes
        }
        breakUndoCoalescing()
    }

    private func changeTypingAttributesUndoably(_ attributes: [NSAttributedString.Key: Any]) {
        let previous = typingAttributes
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.changeTypingAttributesUndoably(previous)
        }
        typingAttributes = attributes
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { didAttachToWindow?() }
    }
}
