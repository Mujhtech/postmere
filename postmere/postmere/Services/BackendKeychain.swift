import Foundation
import Security

nonisolated struct BackendCredential: Codable, Sendable, Equatable {
    let baseURL: String
    let token: String
    let expiresAt: Date?
    let userID: UUID
    let workspaceID: UUID
    var absoluteExpiresAt: Date? = nil

    func isValid(at date: Date) -> Bool {
        expiresAt.map { $0 > date } != false && absoluteExpiresAt.map { $0 > date } != false
    }
}

nonisolated struct BackendPendingRevocation: Codable, Sendable, Identifiable {
    let id: UUID
    let credential: BackendCredential
    let pushInstallationID: UUID?
    var requestedAt: Date? = nil
}

nonisolated protocol BackendCredentialStorage: Sendable {
    func load() async throws -> BackendCredential?
    func save(_ credential: BackendCredential) async throws
    func delete() async throws
    func replace(_ credential: BackendCredential, matchingToken: String) async throws -> Bool
    func pendingRevocations() async throws -> [BackendPendingRevocation]
    func enqueueRevocation(_ item: BackendPendingRevocation) async throws
    func removeRevocation(id: UUID) async throws
}

actor BackendKeychain: BackendCredentialStorage {
    private func identity(account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "app.postmere.server.session",
         kSecAttrAccount: account, kSecUseDataProtectionKeychain: true]
    }
    func load() throws -> BackendCredential? {
        guard let data = try loadData(account: "desktop-session-v1") else { return nil }
        return try JSONDecoder().decode(BackendCredential.self, from: data)
    }
    private func loadData(account: String) throws -> Data? {
        var query = identity(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw BackendKeychainError(status) }
        return data
    }
    func save(_ credential: BackendCredential) throws {
        try saveData(JSONEncoder().encode(credential), account: "desktop-session-v1")
    }
    private func saveData(_ data: Data, account: String) throws {
        let identity = identity(account: account)
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
        try deleteData(account: "desktop-session-v1")
    }
    private func deleteData(account: String) throws {
        let status = SecItemDelete(identity(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BackendKeychainError(status) }
    }

    func replace(_ credential: BackendCredential, matchingToken: String) throws -> Bool {
        guard let current = try load(), current.token == matchingToken, current.baseURL == credential.baseURL,
              current.userID == credential.userID, current.workspaceID == credential.workspaceID else { return false }
        // This actor performs the read/replace without suspension. A late
        // lifetime response cannot recreate a deleted or newly replaced login.
        try save(credential)
        return true
    }

    func pendingRevocations() throws -> [BackendPendingRevocation] {
        guard let data = try loadData(account: "desktop-pending-revocations-v1") else { return [] }
        return try JSONDecoder().decode([BackendPendingRevocation].self, from: data)
    }

    func enqueueRevocation(_ item: BackendPendingRevocation) throws {
        var pending = try pendingRevocations()
        guard !pending.contains(where: { $0.id == item.id }) else { return }
        pending.append(item)
        try saveData(JSONEncoder().encode(pending), account: "desktop-pending-revocations-v1")
    }

    func removeRevocation(id: UUID) throws {
        let pending = try pendingRevocations().filter { $0.id != id }
        if pending.isEmpty { try deleteData(account: "desktop-pending-revocations-v1") }
        else { try saveData(JSONEncoder().encode(pending), account: "desktop-pending-revocations-v1") }
    }
}

nonisolated private struct BackendKeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? { "The secure session could not be stored in Keychain (\(status)). Use a signed build for account connections." }
}
