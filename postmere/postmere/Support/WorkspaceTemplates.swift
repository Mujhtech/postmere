import Foundation

enum WorkspaceTemplates {
    static func export(_ snippet: MailSnippet) throws -> SharedTemplate {
        var total = 0
        let attachments = try snippet.attachments.map { attachment -> SharedTemplateAttachment in
            guard let url = attachment.localURL else { throw BackendError.response(400, "A template file is unavailable.") }
            let bytes = try MailAttachment.boundedFileData(at: url, maximumBytes: 20 * 1024 * 1024 - total)
            total += bytes.count
            guard total <= 20 * 1024 * 1024 else { throw BackendError.tooLarge }
            return SharedTemplateAttachment(filename: attachment.name, mimeType: attachment.mimeType ?? "application/octet-stream", dataBase64: bytes.base64EncodedString())
        }
        return SharedTemplate(title: snippet.title, body: snippet.body, kind: snippet.kind.rawValue, bodyRtfBase64: snippet.bodyRTF?.base64EncodedString(),
                              to: snippet.to, cc: snippet.cc, bcc: snippet.bcc, subject: snippet.subject, attachments: attachments)
    }

    static func importTemplate(_ template: SharedTemplate, store: MailStore) throws -> MailSnippet {
        guard template.body.utf8.count <= 1024 * 1024, template.attachments.count <= 20 else { throw BackendError.tooLarge }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [URL] = []
        var total = 0
        for file in template.attachments {
            guard URL(fileURLWithPath: file.filename).lastPathComponent == file.filename,
                  !file.filename.contains("\\"), !file.filename.isEmpty, file.filename != ".", file.filename != "..",
                  let data = Data(base64Encoded: file.dataBase64) else { throw BackendError.invalidResponse }
            total += data.count
            guard total <= 20 * 1024 * 1024 else { throw BackendError.tooLarge }
            let fileFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: fileFolder, withIntermediateDirectories: true)
            let url = fileFolder.appendingPathComponent(file.filename)
            try data.write(to: url, options: .atomic); files.append(url)
        }
        let attachments = try store.importTemplateAttachments(from: files)
        let rtf = template.bodyRtfBase64.flatMap { Data(base64Encoded: $0) }
        return MailSnippet(title: template.title, body: template.body, kind: MailSnippet.Kind(rawValue: template.kind) ?? .snippet,
                           bodyRTF: rtf, to: template.to, cc: template.cc, bcc: template.bcc, subject: template.subject, attachments: attachments)
    }
}
