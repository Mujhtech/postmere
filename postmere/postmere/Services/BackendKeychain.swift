import Foundation
import Security

nonisolated struct BackendCredential: Codable, Sendable {
    let baseURL: String
    let token: String
    let expiresAt: Date
    let userID: UUID
    let workspaceID: UUID
}

nonisolated protocol BackendCredentialStorage: Sendable {
    func load() async throws -> BackendCredential?
    func save(_ credential: BackendCredential) async throws
    func delete() async throws
}

actor BackendKeychain: BackendCredentialStorage {
    private var identity: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "app.postmere.server.session",
         kSecAttrAccount: "desktop-session-v1", kSecUseDataProtectionKeychain: true]
    }
    func load() throws -> BackendCredential? {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw BackendKeychainError(status) }
        return try JSONDecoder().decode(BackendCredential.self, from: data)
    }
    func save(_ credential: BackendCredential) throws {
        let data = try JSONEncoder().encode(credential)
        var query = identity
        query[kSecValueData] = data
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard updated == errSecSuccess else { throw BackendKeychainError(updated) }
        } else if status != errSecSuccess { throw BackendKeychainError(status) }
    }
    func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BackendKeychainError(status) }
    }
}

nonisolated private struct BackendKeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? { "The secure session could not be stored in Keychain (\(status)). Use a signed build for account connections." }
}
