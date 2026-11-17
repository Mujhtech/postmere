import Foundation

extension MailStore {
    var draftForTemplates: MailTemplateDraft {
        MailTemplateDraft(headers: MailTemplateHeaders(to: draftTo, cc: draftCc, bcc: draftBcc,
            subject: draftSubject, attachments: draftAttachments), body: draftBody, bodyRTF: draftBodyRTF)
    }

    /// Deliberately excludes body fields: the native editor owns their undo.
    func applyTemplateHeaders(_ fields: MailTemplateHeaders) {
        persistenceSuspended += 1
        draftTo = fields.to
        draftCc = fields.cc
        draftBcc = fields.bcc
        draftSubject = fields.subject
        draftAttachments = fields.attachments
        persistenceSuspended -= 1
        draftChanged()
    }

    func importTemplateAttachments(from urls: [URL]) throws -> [MailAttachment] {
        var imported: [MailAttachment] = []
        do {
            for url in urls {
                imported.append(try MailAttachment.importFile(at: url, storageDirectory:
                    attachmentStorageDirectory.appendingPathComponent("Templates", isDirectory: true)))
            }
            return imported
        } catch {
            for attachment in imported {
                if let url = attachment.localURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
            throw error
        }
    }
}
