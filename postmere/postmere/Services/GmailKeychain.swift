import Foundation
import Security

nonisolated protocol GmailCredentialStorage: Sendable {
    func load() async throws -> GmailCredentials?
    func save(_ credentials: GmailCredentials) async throws
    func delete() async throws
}

/// Isolated from the UI actor because Keychain calls can block.
actor GmailKeychain: GmailCredentialStorage {
    private let service: String
    init(service: String = "app.postmere.gmail.oauth") { self.service = service }

    private var identity: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "desktop-session-v1", kSecUseDataProtectionKeychain: true]
    }

    func load() throws -> GmailCredentials? {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GmailError.keychain(status) }
        guard let data = item as? Data else { throw GmailError.keychain(errSecDecode) }
        return try JSONDecoder().decode(GmailCredentials.self, from: data)
    }

    func save(_ credentials: GmailCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var add = identity
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess: return
        case errSecDuplicateItem:
            let status = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard status == errSecSuccess else { throw GmailError.keychain(status) }
        case let status: throw GmailError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GmailError.keychain(status) }
    }
}
