import SwiftUI
import QuickLookUI
import PDFKit
import UniformTypeIdentifiers

struct AttachmentPreviewSheet: View {
    let attachment: MailAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AttachmentIconView(attachment: attachment, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name)
                        .font(PostmereTheme.sheetTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(attachment.name)
                    Text(attachment.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            if let url = attachment.localURL {
                Group {
                    if isPDF(url) {
                        PDFAttachmentPreview(url: url, attachment: attachment)
                    } else {
                        NativeAttachmentPreview(url: url)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No File Included")
                    } icon: {
                        AttachmentIconView(attachment: attachment, size: 48)
                    }
                } description: {
                    Text("This sample attachment does not contain a file.")
                }
            }
        }
        .frame(width: 600, height: 480)
    }

    private func isPDF(_ url: URL) -> Bool {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf"
    }
}

/// PDFs stay in-process so their scroll views can honor the app's indicator policy.
private struct PDFAttachmentPreview: View {
    let url: URL
    let attachment: MailAttachment
    @State private var document: PDFDocument?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let document {
                NativePDFPreview(document: document)
            } else if didLoad {
                ContentUnavailableView {
                    Label {
                        Text("Unable to Open PDF")
                    } icon: {
                        AttachmentIconView(attachment: attachment, size: 48)
                    }
                } description: {
                    Text("The file could not be read as a PDF document.")
                }
            } else {
                ProgressView("Loading attachment…")
            }
        }
        .task(id: url) {
            document = PDFDocument(url: url)
            didLoad = true
        }
    }
}

private struct NativePDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> ScrollbarFreePDFView {
        let view = ScrollbarFreePDFView(frame: .zero)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: ScrollbarFreePDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        view.layoutDocumentView()
    }

    static func dismantleNSView(_ view: ScrollbarFreePDFView, coordinator: ()) {
        view.document = nil
    }
}

/// Only removes visual indicators; PDFKit keeps scrolling, zooming, and selection.
private final class ScrollbarFreePDFView: PDFView {
    private var scrollViewObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var scrollerObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var isSuppressingIndicators = false

    override func layout() {
        super.layout()
        hideScrollbars(in: self)
    }

    override func layoutDocumentView() {
        super.layoutDocumentView()
        hideScrollbars(in: self)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        hideScrollbars(in: subview)
    }

    private func hideScrollbars(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            observeScrollView(scrollView)
            suppressIndicators(in: scrollView)
        }
        for child in view.subviews { hideScrollbars(in: child) }
    }

    private func observeScrollView(_ scrollView: NSScrollView) {
        let id = ObjectIdentifier(scrollView)
        guard scrollViewObservations[id] == nil else { return }
        // PDFKit can restore these properties after its layout pass. Keep this
        // policy attached only to the scroll views belonging to this preview.
        scrollViewObservations[id] = [
            scrollView.observe(\.hasVerticalScroller) { [weak self] view, _ in self?.suppressIndicators(in: view) },
            scrollView.observe(\.hasHorizontalScroller) { [weak self] view, _ in self?.suppressIndicators(in: view) },
            scrollView.observe(\.verticalScroller) { [weak self] view, _ in self?.suppressIndicators(in: view) },
            scrollView.observe(\.horizontalScroller) { [weak self] view, _ in self?.suppressIndicators(in: view) },
            scrollView.observe(\.scrollerStyle) { [weak self] view, _ in self?.suppressIndicators(in: view) }
        ]
    }

    private func suppressIndicators(in scrollView: NSScrollView) {
        guard !isSuppressingIndicators else { return }
        isSuppressingIndicators = true
        defer { isSuppressingIndicators = false }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
        if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
        for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap({ $0 }) {
            let id = ObjectIdentifier(scroller)
            if scrollerObservations[id] == nil {
                scrollerObservations[id] = [
                    scroller.observe(\.isHidden) { [weak self, weak scrollView] _, _ in
                        if let scrollView { self?.suppressIndicators(in: scrollView) }
                    },
                    scroller.observe(\.alphaValue) { [weak self, weak scrollView] _, _ in
                        if let scrollView { self?.suppressIndicators(in: scrollView) }
                    }
                ]
            }
            if !scroller.isHidden { scroller.isHidden = true }
            if scroller.alphaValue != 0 { scroller.alphaValue = 0 }
        }
    }
}

/// SwiftUI owns presentation; Quick Look owns only the embedded file preview.
private struct NativeAttachmentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = ScrollbarFreePreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Quick Look is an AppKit view and does not inherit SwiftUI's indicator visibility.
private final class ScrollbarFreePreviewView: QLPreviewView {
    override func layout() {
        super.layout()
        hideScrollbars(in: self)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        hideScrollbars(in: subview)
    }

    private func hideScrollbars(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
            if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
        }
        for child in view.subviews { hideScrollbars(in: child) }
    }
}
