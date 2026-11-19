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

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(frame: .zero)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        view.layoutDocumentView()
    }

    static func dismantleNSView(_ view: PDFView, coordinator: ()) {
        view.document = nil
    }
}

/// SwiftUI owns presentation; Quick Look owns only the embedded file preview.
private struct NativeAttachmentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
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
