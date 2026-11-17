import AppKit
import Foundation
import Observation

enum MailSignatureContext: String, Codable, CaseIterable {
    case newMessage, reply, forward
}

/// Account identifiers are strings so connected addresses and future provider
/// account IDs can share this model without changing the saved format.
struct MailSignatureAccount: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String = ""
}

struct MailSignature: Codable, Equatable {
    var text = ""
    var rtfData: Data?
    var includeInNewMessages = true
    var includeInReplies = true
    var includeInForwards = true

    init(text: String = "", rtfData: Data? = nil, includeInNewMessages: Bool = true,
         includeInReplies: Bool = true, includeInForwards: Bool = true) {
        self.text = text
        self.rtfData = rtfData
        self.includeInNewMessages = includeInNewMessages
        self.includeInReplies = includeInReplies
        self.includeInForwards = includeInForwards
    }

    func applies(to context: MailSignatureContext) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch context {
        case .newMessage: return includeInNewMessages
        case .reply: return includeInReplies
        case .forward: return includeInForwards
        }
    }

    private enum CodingKeys: String, CodingKey { case text, rtfData, includeInNewMessages, includeInReplies, includeInForwards }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        rtfData = try values.decodeIfPresent(Data.self, forKey: .rtfData)
        includeInNewMessages = try values.decodeIfPresent(Bool.self, forKey: .includeInNewMessages) ?? true
        includeInReplies = try values.decodeIfPresent(Bool.self, forKey: .includeInReplies) ?? true
        includeInForwards = try values.decodeIfPresent(Bool.self, forKey: .includeInForwards) ?? true
    }
}

struct MailSignatureBody {
    let text: String
    let rtfData: Data?
}

/// Local preferences contain signature text only, never provider credentials.
/// A failed decode is kept intact and blocks writes rather than replacing data.
@MainActor
@Observable
final class MailSignatureStore {
    static let shared = MailSignatureStore()
    static let storageKey = "accountSignatures.v1"

    private(set) var signatures: [String: MailSignature] = [:]
    private(set) var loadError: String?
    @ObservationIgnored private let defaults: UserDefaults

    private struct Snapshot: Codable {
        var schemaVersion = 1
        var signatures: [String: MailSignature]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == 1 else { throw SignatureStorageError.unsupportedVersion }
            signatures = snapshot.signatures
        } catch {
            loadError = "Saved signatures could not be opened: \(error.localizedDescription) The saved data has not been changed."
        }
    }

    func signature(for accountID: String) -> MailSignature {
        signatures[Self.key(accountID)] ?? MailSignature(text: defaults.string(forKey: "signatureText") ?? "")
    }

    func hasCustomSignature(for accountID: String) -> Bool { signatures[Self.key(accountID)] != nil }

    func save(_ signature: MailSignature, for accountID: String) throws {
        guard loadError == nil else { throw SignatureStorageError.unreadableSavedData }
        let key = Self.key(accountID)
        guard !key.isEmpty else { throw SignatureStorageError.missingAccount }
        var updated = signatures
        var value = signature
        if value.text.isEmpty { value.rtfData = nil }
        updated[key] = value
        let data = try JSONEncoder().encode(Snapshot(signatures: updated))
        defaults.set(data, forKey: Self.storageKey)
        signatures = updated
    }

    /// Call only when starting a new composition. Changing an account setting
    /// intentionally has no side effect on an already edited draft.
    func initialBody(for accountID: String, context: MailSignatureContext, quotedText: String? = nil) -> MailSignatureBody {
        let signature = signature(for: accountID)
        let rich = NSMutableAttributedString(string: "")
        if signature.applies(to: context) {
            rich.append(MailTemplate.richBody(text: "\n\n", rtf: nil))
            rich.append(MailTemplate.richBody(text: signature.text, rtf: signature.rtfData))
        }
        if let quotedText, !quotedText.isEmpty {
            rich.append(MailTemplate.richBody(text: "\n\n" + quotedText, rtf: nil))
        }
        return MailSignatureBody(text: rich.string, rtfData: MailTemplate.encodeRTF(rich))
    }

    private static func key(_ accountID: String) -> String {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") ? trimmed.lowercased() : trimmed
    }
}

private enum SignatureStorageError: LocalizedError {
    case unsupportedVersion, unreadableSavedData, missingAccount
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This signature format was saved by a newer version of Postmere."
        case .unreadableSavedData: "The existing signature preferences must be recovered before saving changes."
        case .missingAccount: "Choose an account before saving a signature."
        }
    }
}
