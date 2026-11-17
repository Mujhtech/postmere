import Foundation

@main
struct AttachmentTypeChecks {
    static func main() {
        let fixtures: [(String, String?, AttachmentFileType.Kind, String)] = [
            ("Quarterly Report.PDF", nil, .pdf, "PDF"),
            ("Plan.docx", "application/octet-stream", .document, "DOCX"),
            ("Budget.xlsx", "application/zip", .spreadsheet, "XLSX"),
            ("Export.CSV", "text/plain", .spreadsheet, "CSV"),
            ("Deck.key", nil, .presentation, "KEY"),
            ("Photo.HEIC", nil, .image, "HEIC"),
            ("Brand.svg", "application/xml", .image, "SVG"),
            ("Memo.m4a", "video/mp4", .audio, "M4A"),
            ("Film.webm", nil, .video, "WEBM"),
            ("Backup.tar.gz", nil, .archive, "GZ"),
            ("Widget.swift", "text/plain", .code, "SWIFT"),
            ("Component.ts", "text/plain", .code, "TS"),
            ("Recording.ts", "video/mp2t", .video, "TS"),
            ("Recording.ogg", "video/ogg", .video, "OGG"),
            ("Dockerfile", nil, .code, "CODE"),
            (".gitignore", nil, .code, "CODE"),
            ("README.md", nil, .document, "MD"),
            ("attachment", " APPLICATION/PDF ; charset=binary", .pdf, "PDF"),
            ("attachment", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", .spreadsheet, "XLSX"),
            ("attachment", "application/vnd.openxmlformats-officedocument.presentationml.presentation", .presentation, "PPTX"),
            ("attachment", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", .document, "DOCX"),
            ("attachment", "application/vnd.apple.keynote", .presentation, "KEY"),
            ("attachment", "image/jpeg", .image, "JPEG"),
            ("attachment", "image/png", .image, "PNG"),
            ("response", "application/problem+json", .code, "CODE"),
            ("unknown.blob", "application/pdf", .pdf, "BLOB"),
            ("attachment.bin", "application/octet-stream", .file, "BIN"),
            ("attachment.bin", "image/png", .image, "BIN"),
            ("unknown.unreasonablylongextension", nil, .file, "FILE"),
            ("attachment", "application/octet-stream", .file, "FILE"),
            ("attachment", "not a mime type", .file, "FILE"),
        ]
        for (name, mime, expectedKind, expectedBadge) in fixtures {
            let actual = AttachmentFileType(name: name, mimeType: mime)
            precondition(actual.kind == expectedKind, "\(name), \(mime ?? "no MIME"): expected \(expectedKind), got \(actual.kind)")
            precondition(actual.badge == expectedBadge, "\(name): expected badge \(expectedBadge), got \(actual.badge)")
        }

        // No file needs to exist: a provider attachment and a missing local file
        // still retain their type, and an opaque cache name cannot override it.
        let missing = URL(fileURLWithPath: "/does-not-exist/renamed.tmp")
        let pdf = AttachmentFileType(name: "Contract.pdf", mimeType: "application/octet-stream", localURL: missing)
        precondition(pdf.kind == .pdf && pdf.badge == "PDF" && pdf.contentTypeIdentifier == "com.adobe.pdf")
        let localFallback = AttachmentFileType(name: "Untitled", localURL: URL(fileURLWithPath: "/does-not-exist/notes.txt"))
        precondition(localFallback.kind == .document && localFallback.badge == "TXT")
        let m4a = AttachmentFileType(name: "Voice.m4a")
        precondition(m4a.kind == .audio, "MPEG-4 audio must not use the video motif")
        let typescript = AttachmentFileType(name: "Widget.ts", mimeType: "text/plain")
        precondition(typescript.contentTypeIdentifier == "public.plain-text" || typescript.contentTypeIdentifier?.contains("typescript") == true, "TypeScript thumbnails must not request a video decoder")
        print("PASS: \(fixtures.count + 4) attachment classification cases, including remote/missing files, MIME normalization, Office ZIP ambiguity, and media subtypes")
    }
}
