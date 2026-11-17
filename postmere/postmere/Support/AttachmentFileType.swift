import Foundation
import UniformTypeIdentifiers

/// Classifies attachment metadata without reading the file or downloading it.
nonisolated struct AttachmentFileType: Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case pdf, document, spreadsheet, presentation, image, audio, video, archive, code, file

        var title: String {
            switch self {
            case .pdf: "PDF document"
            case .document: "Document"
            case .spreadsheet: "Spreadsheet"
            case .presentation: "Presentation"
            case .image: "Image"
            case .audio: "Audio"
            case .video: "Video"
            case .archive: "Archive"
            case .code: "Source code"
            case .file: "File"
            }
        }

        var fallbackBadge: String {
            switch self {
            case .pdf: "PDF"
            case .document: "DOC"
            case .spreadsheet: "SHEET"
            case .presentation: "SLIDE"
            case .image: "IMAGE"
            case .audio: "AUDIO"
            case .video: "VIDEO"
            case .archive: "ZIP"
            case .code: "CODE"
            case .file: "FILE"
            }
        }
    }

    let kind: Kind
    let badge: String
    let contentTypeIdentifier: String?

    init(name: String, mimeType: String? = nil, localURL: URL? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let namedExtension = (name as NSString).pathExtension.lowercased()
        let fileExtension = namedExtension.isEmpty ? (localURL?.pathExtension.lowercased() ?? "") : namedExtension
        let mime = mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let extensionType = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        let mimeType = mime.isEmpty ? nil : UTType(mimeType: mime)
        let isGenericExtension = ["bin", "dat", "tmp", "file"].contains(fileExtension)
        let extensionKind = Self.kind(forExtension: fileExtension) ?? (isGenericExtension ? nil : Self.kind(for: extensionType))
        let mimeKind = Self.kind(forMIME: mime) ?? Self.kind(for: mimeType)
        let filename = (name as NSString).lastPathComponent.lowercased()
        let isSourceFilename = ["dockerfile", "makefile", "gemfile", "rakefile", ".gitignore", ".env", ".editorconfig", ".npmrc"].contains(filename)

        // Extensions are more useful than the generic ZIP/octet-stream MIME types
        // mail providers sometimes assign to Office files. MIME disambiguates TS/OGG.
        if ["ts", "ogg"].contains(fileExtension), let mimeKind, [.audio, .video].contains(mimeKind) {
            kind = mimeKind
        } else {
            kind = extensionKind ?? mimeKind ?? (isSourceFilename ? .code : .file)
        }

        let resolvedType: UTType?
        if extensionKind != nil, Self.kind(for: extensionType) == kind {
            resolvedType = extensionType
        } else if mimeKind == kind {
            resolvedType = mimeType
        } else {
            resolvedType = nil
        }
        // A .ts source file is otherwise registered as MPEG transport video on
        // some Macs; provide a compatible textual type to Quick Look instead.
        if resolvedType?.isDynamic == false {
            contentTypeIdentifier = resolvedType?.identifier
        } else {
            contentTypeIdentifier = switch kind {
            case .pdf: UTType.pdf.identifier
            case .code: UTType.plainText.identifier
            default: nil
            }
        }

        let inferredExtension = Self.preferredExtension(forMIME: mime) ?? resolvedType?.preferredFilenameExtension ?? ""
        let badgeExtension = fileExtension.isEmpty ? inferredExtension : fileExtension
        let isReadableExtension = !badgeExtension.isEmpty && badgeExtension.count <= 7
            && badgeExtension.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        badge = isReadableExtension ? badgeExtension.uppercased() : kind.fallbackBadge
    }

    private static func preferredExtension(forMIME mime: String) -> String? {
        switch mime {
        case "application/pdf", "application/x-pdf": "pdf"
        case "image/jpeg", "image/jpg": "jpeg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/tiff": "tiff"
        case "image/svg+xml": "svg"
        case "image/heic": "heic"
        case "image/heif": "heif"
        case "image/webp": "webp"
        case "image/avif": "avif"
        case "image/bmp": "bmp"
        case "audio/mpeg": "mp3"
        case "audio/mp4": "m4a"
        case "audio/aac": "aac"
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/flac": "flac"
        case "audio/ogg": "ogg"
        case "audio/opus": "opus"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/webm": "webm"
        case "video/mpeg": "mpeg"
        case "application/zip", "application/x-zip-compressed": "zip"
        case "application/x-rar-compressed", "application/vnd.rar": "rar"
        case "application/x-7z-compressed": "7z"
        case "application/gzip", "application/x-gzip": "gz"
        case "application/x-tar": "tar"
        case "text/plain": "txt"
        case "text/markdown": "md"
        case "application/json": "json"
        case "application/xml", "text/xml": "xml"
        case "text/html": "html"
        case "text/css": "css"
        case "text/javascript", "application/javascript": "js"
        case "application/typescript": "ts"
        case "application/msword": "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx"
        case "application/vnd.ms-excel": "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx"
        case "application/vnd.ms-powerpoint": "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx"
        case "application/vnd.apple.pages": "pages"
        case "application/vnd.apple.numbers": "numbers"
        case "application/vnd.apple.keynote": "key"
        case "application/vnd.oasis.opendocument.text": "odt"
        case "application/vnd.oasis.opendocument.spreadsheet": "ods"
        case "application/vnd.oasis.opendocument.presentation": "odp"
        case "text/csv": "csv"
        case "text/tab-separated-values": "tsv"
        default: nil
        }
    }

    private static func kind(forExtension ext: String) -> Kind? {
        switch ext {
        case "pdf": .pdf
        case "doc", "docx", "docm", "dot", "dotx", "pages", "odt", "rtf", "rtfd", "txt", "md", "markdown", "log", "epub": .document
        case "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "numbers", "ods", "csv", "tsv": .spreadsheet
        case "ppt", "pptx", "pptm", "pps", "ppsx", "key", "odp": .presentation
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "webp", "avif", "bmp", "svg", "ico", "icns", "psd", "raw", "dng", "cr2", "cr3", "nef", "arw": .image
        case "mp3", "m4a", "aac", "aif", "aiff", "wav", "flac", "ogg", "opus", "mid", "midi", "wma": .audio
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp": .video
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "dmg", "iso", "aar": .archive
        case "swift", "js", "jsx", "ts", "tsx", "json", "jsonl", "xml", "html", "htm", "css", "scss", "sass", "less", "py", "rb", "php", "go", "rs", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "sh", "bash", "zsh", "fish", "sql", "yaml", "yml", "toml", "vue", "svelte", "ipynb": .code
        default: nil
        }
    }

    private static func kind(forMIME mime: String) -> Kind? {
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        if mime.contains("spreadsheet") || mime.contains("ms-excel") || mime == "text/csv" || mime == "text/tab-separated-values" || mime == "application/vnd.apple.numbers" { return .spreadsheet }
        if mime.contains("presentation") || mime.contains("powerpoint") || mime == "application/vnd.apple.keynote" { return .presentation }
        if mime.contains("wordprocessingml") || mime == "application/msword" || mime == "application/vnd.apple.pages" || mime == "application/vnd.oasis.opendocument.text" { return .document }
        if mime.hasSuffix("+json") || mime.hasSuffix("+xml") { return .code }
        switch mime {
        case "application/pdf", "application/x-pdf": return .pdf
        case "application/zip", "application/x-zip-compressed", "application/x-rar-compressed", "application/vnd.rar", "application/x-7z-compressed", "application/gzip", "application/x-gzip", "application/x-tar", "application/x-bzip2", "application/x-xz": return .archive
        case "application/json", "application/xml", "text/xml", "text/html", "text/css", "text/javascript", "application/javascript", "application/typescript", "text/x-python", "text/x-swift", "application/x-sh", "application/yaml", "text/yaml": return .code
        case "application/rtf", "text/rtf", "application/epub+zip": return .document
        default: return mime.hasPrefix("text/") ? .document : nil
        }
    }

    private static func kind(for type: UTType?) -> Kind? {
        guard let type, !type.isDynamic else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) { return .spreadsheet }
        if type.conforms(to: .presentation) { return .presentation }
        if type.conforms(to: .image) { return .image }
        // MPEG-4 audio also conforms to movie; audio must be checked first.
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json) || type.conforms(to: .xml) || type.conforms(to: .html) { return .code }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .document }
        return nil
    }
}
