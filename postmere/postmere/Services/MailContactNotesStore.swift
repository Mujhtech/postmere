import Foundation
import Observation

struct MailContactNote: Codable, Equatable, Identifiable {
    var email: String
    var accountKey: String
    var text: String
    var updatedAt: Date
    var id: String { "\(accountKey.count)#\(accountKey)\(email)" }
}

/// Private contact notes have their own local-only file. They are never added
/// to draft text, outgoing message metadata, or provider sync payloads.
@MainActor
@Observable
final class MailContactNotesStore {
    static let shared = MailContactNotesStore()
    private(set) var records: [String: MailContactNote] = [:]
    private(set) var storageError: String?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var isBlocked = false

    private struct Snapshot: Codable {
        var schemaVersion = 1
        var records: [String: MailContactNote]
    }

    init(fileURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Postmere/Contacts/contact-notes.json")) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == 1, snapshot.records.allSatisfy({ $0.key == $0.value.id }) else {
                throw MailContactNoteError.invalidStorage
            }
            records = snapshot.records
        } catch {
            isBlocked = true
            storageError = "Private contact notes could not be opened: \(error.localizedDescription) The saved file has not been changed."
        }
    }

    func note(for email: String, accountKey: String) -> String {
        records[MailContactNote(email: MailContactIdentity.email(email), accountKey: accountKey, text: "", updatedAt: .distantPast).id]?.text ?? ""
    }

    func save(_ text: String, for email: String, accountKey: String) throws {
        guard !isBlocked else { throw MailContactNoteError.invalidStorage }
        guard text.utf8.count <= 64 * 1_024 else { throw MailContactNoteError.noteTooLong }
        let email = MailContactIdentity.email(email)
        guard !email.isEmpty, !accountKey.isEmpty else { throw MailContactNoteError.missingIdentity }
        let note = MailContactNote(email: email, accountKey: accountKey, text: text, updatedAt: .now)
        var updated = records
        if text.isEmpty { updated.removeValue(forKey: note.id) } else { updated[note.id] = note }
        let data = try JSONEncoder().encode(Snapshot(records: updated))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            records = updated
            storageError = nil
        } catch {
            storageError = "The private note could not be saved: \(error.localizedDescription)"
            throw error
        }
    }
}

private enum MailContactNoteError: LocalizedError {
    case invalidStorage, noteTooLong, missingIdentity
    var errorDescription: String? {
        switch self {
        case .invalidStorage: "The saved notes file must be recovered before making changes."
        case .noteTooLong: "Keep this note below 64 KB."
        case .missingIdentity: "A contact and account are required for a private note."
        }
    }
}
