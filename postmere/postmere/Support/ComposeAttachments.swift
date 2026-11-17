import Foundation

extension MailAttachment {
    /// Reject large or non-regular files before allocation, and retain a hard
    /// limit if a local file grows between its metadata check and the read.
    static func boundedFileData(at url: URL, maximumBytes: Int) throws -> Data {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true else { throw AttachmentImportError.notAFile(url.lastPathComponent) }
        guard maximumBytes >= 0, (properties.fileSize ?? 0) <= maximumBytes else { throw AttachmentImportError.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: min(65_535, maximumBytes - data.count) + 1), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - data.count else { throw AttachmentImportError.tooLarge }
            data.append(chunk)
        }
        return data
    }

    /// Keeps an app-owned copy so saved drafts remain usable after the source file moves.
    static func importFile(at url: URL, storageDirectory: URL = MailPersistence.defaultDirectory.appendingPathComponent("Attachments", isDirectory: true)) throws -> MailAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true else { throw AttachmentImportError.notAFile(url.lastPathComponent) }

        let directory = storageDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(properties.fileSize ?? 0), countStyle: .file)
        let type = url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
        return MailAttachment(name: url.lastPathComponent, detail: "\(type) · \(size)", localURL: copy, byteCount: properties.fileSize)
    }
}

private enum AttachmentImportError: LocalizedError {
    case notAFile(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notAFile(let name): "“\(name)” is a folder. Choose individual files to attach."
        case .tooLarge: "These files exceed the upload limit. Use smaller attachments and try again."
        }
    }
}
