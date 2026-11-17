import Foundation
import Observation
import CryptoKit

@MainActor
@Observable
final class BackendSession {
    private(set) var accounts: [BackendAccount] = []
    private(set) var disconnectingAccountIDs: Set<UUID> = []
    private(set) var credential: BackendCredential?
    private(set) var isBusy = false
    var errorMessage: String?
    var statusMessage: String?
    var baseURL: String
    @ObservationIgnored private let storage: any BackendCredentialStorage
    @ObservationIgnored private let configuration: URLSessionConfiguration
    @ObservationIgnored private var transport: BackendHTTPClient?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var accountsGeneration = UUID()
    var isConnected: Bool { credential != nil }

    nonisolated struct Login: Encodable, Sendable { let email: String; let password: String; let workspaceId: UUID }
    nonisolated struct SessionResponse: Decodable, Sendable {
        let token: String
        let expiresAt: Date
        let absoluteExpiresAt: Date
        let sessionId: UUID
        let userId: UUID
        let workspaceId: UUID
        let role: String
    }
    nonisolated struct Me: Decodable, Sendable {
        let sessionId: UUID; let userId: UUID; let workspaceId: UUID; let role: String; let email: String
    }
    nonisolated struct OAuthStart: Decodable, Sendable {
        let connectionId: UUID; let authorizationUrl: String; let expiresAt: Date
    }
    nonisolated struct OAuthStatus: Decodable, Sendable {
        let status: String; let accountId: UUID?; let error: String?
    }

    init(storage: (any BackendCredentialStorage)? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.storage = storage ?? BackendKeychain()
        self.configuration = configuration.copy() as! URLSessionConfiguration
        baseURL = UserDefaults.standard.string(forKey: "postmereServerURL") ?? ""
    }

    func restore() async {
        guard credential == nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let requestGeneration = generation
        do {
            guard let saved = try await storage.load() else { return }
            guard requestGeneration == generation else { return }
            guard saved.expiresAt > .now else { try await storage.delete(); return }
            let client = try BackendHTTPClient(baseURL: saved.baseURL, configuration: configuration)
            let me: Me = try await client.request("GET", "/v1/auth/me", token: saved.token)
            guard requestGeneration == generation else { return }
            guard me.userId == saved.userID, me.workspaceId == saved.workspaceID else {
                try await storage.delete()
                throw BackendError.notConnected
            }
            credential = saved
            baseURL = saved.baseURL
            transport = client
            try await refreshAccounts()
        } catch {
            if requestGeneration == generation {
                if case BackendError.response(401, _) = error { try? await storage.delete() }
                guard requestGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func login(email: String, password: String, workspaceID: String) async {
        guard !isBusy, credential == nil else { return }
        isBusy = true
        generation = UUID()
        let requestGeneration = generation
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        var issued: (BackendHTTPClient, String)?
        var savedToken = false
        do {
            guard let workspace = UUID(uuidString: workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw BackendError.response(400, "Enter the workspace ID supplied by your server administrator.")
            }
            let loginEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = try BackendHTTPClient(baseURL: baseURL, configuration: configuration)
            let response: SessionResponse = try await client.request("POST", "/v1/auth/login",
                body: Login(email: loginEmail, password: password, workspaceId: workspace))
            issued = (client, response.token)
            guard requestGeneration == generation else { throw BackendError.notConnected }
            guard response.workspaceId == workspace, response.expiresAt > .now,
                  response.expiresAt <= response.absoluteExpiresAt, !response.token.isEmpty,
                  ["owner", "admin", "member"].contains(response.role) else { throw BackendError.invalidResponse }
            let me: Me = try await client.request("GET", "/v1/auth/me", token: response.token)
            guard requestGeneration == generation else { throw BackendError.notConnected }
            guard me.userId == response.userId, me.workspaceId == workspace,
                  me.sessionId == response.sessionId, me.role == response.role,
                  me.email.caseInsensitiveCompare(loginEmail) == .orderedSame else { throw BackendError.invalidResponse }
            let saved = BackendCredential(baseURL: client.baseURL.absoluteString, token: response.token,
                                          expiresAt: response.expiresAt, userID: response.userId, workspaceID: response.workspaceId)
            try await storage.save(saved)
            savedToken = true
            guard requestGeneration == generation else { throw BackendError.notConnected }
            credential = saved
            transport = client
            UserDefaults.standard.set(saved.baseURL, forKey: "postmereServerURL")
            // The session is installed. A later account-list failure should not
            // revoke a valid session; 401 handling clears it independently.
            issued = nil
            try await refreshAccounts()
            guard requestGeneration == generation else { return }
            statusMessage = "Connected to your Postmere workspace."
        } catch {
            if let (client, token) = issued {
                if savedToken { try? await storage.delete() }
                let _: BackendEmpty? = try? await client.request("POST", "/v1/auth/logout", token: token)
            }
            if requestGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    func logout() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let saved = credential
        let client = transport
        // Invalidate pending mail/restore responses before either storage or
        // network operations suspend. Session transitions remain busy until the
        // old credential deletion has finished, so it cannot delete a new login.
        clearSession()
        let requestGeneration = generation
        var deletionError: Error?
        do { try await storage.delete() } catch { deletionError = error }
        var revocationError: Error?
        if let saved, let client {
            do { let _: BackendEmpty = try await client.request("POST", "/v1/auth/logout", token: saved.token) }
            catch { revocationError = error }
        }
        guard requestGeneration == generation else { return }
        if deletionError == nil {
            statusMessage = "Signed out on this Mac."
            errorMessage = revocationError == nil ? nil : "The server could not confirm revocation. This Mac’s token was removed; the server session may remain active until it expires."
        } else {
            statusMessage = "Signed out of this open window."
            errorMessage = "Could not remove the saved Keychain session. It may be restored after relaunch; try signing out again."
        }
    }

    func clearSession() {
        generation = UUID()
        credential = nil
        transport = nil
        accountsGeneration = UUID()
        accounts = []
        disconnectingAccountIDs = []
        RemoteAccountRegistry.accounts = []
    }

    var scope: String? {
        guard let credential else { return nil }
        let origin = SHA256.hash(data: Data(credential.baseURL.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(origin):\(credential.workspaceID.uuidString.lowercased()):\(credential.userID.uuidString.lowercased())"
    }

    func refreshAccounts() async throws {
        let requestGeneration = generation
        accountsGeneration = UUID()
        let refreshGeneration = accountsGeneration
        let result: [BackendAccount] = try await request("GET", "/v1/mail/accounts")
        guard requestGeneration == generation, refreshGeneration == accountsGeneration, let scope else { return }
        // Account IDs, not provider names or email addresses, identify accounts.
        // Keep the full list and reject ambiguous duplicate IDs without losing
        // the previously installed registry.
        guard Set(result.map(\.id)).count == result.count else { throw BackendError.invalidResponse }
        accounts = result
        installAccountRegistry(scope: scope)
    }

    private func installAccountRegistry(scope: String) {
        RemoteAccountRegistry.accounts = accounts.map {
            RemoteAccountIdentity(localID: "remote:\(scope):\($0.id.uuidString.lowercased())", accountID: $0.id,
                                  scope: scope, email: $0.email, displayName: $0.displayName ?? $0.email,
                                  provider: $0.provider, status: $0.status)
        }
    }

    func isAccountConnected(_ id: UUID, scope expectedScope: String) -> Bool {
        scope == expectedScope && !disconnectingAccountIDs.contains(id)
            && accounts.contains { $0.id == id && $0.status == "connected" }
    }

    func disconnectAccount(id: UUID) async throws {
        guard let accountScope = scope, accounts.contains(where: { $0.id == id }),
              !disconnectingAccountIDs.contains(id) else { throw BackendError.notConnected }
        let requestGeneration = generation
        disconnectingAccountIDs.insert(id)
        // A list requested before this mutation must not reinstall an account
        // after its confirmed removal.
        accountsGeneration = UUID()
        defer {
            if requestGeneration == generation { disconnectingAccountIDs.remove(id) }
        }
        let _: BackendEmpty = try await request("DELETE", "/v1/mail/accounts/\(id.uuidString)")
        guard requestGeneration == generation, scope == accountScope else { throw BackendError.notConnected }
        accountsGeneration = UUID()
        accounts.removeAll { $0.id == id }
        installAccountRegistry(scope: accountScope)
        statusMessage = "Account disconnected. Cached mail and drafts remain on this Mac."
    }

    nonisolated struct OAuthOptions: Encodable, Sendable { let calendarAccess: Bool }

    func startOAuth(provider: String, calendarAccess: Bool = false) async throws -> OAuthStart {
        guard ["gmail", "microsoft"].contains(provider) else { throw BackendError.invalidURL }
        return try await request("POST", "/v1/mail/oauth/\(provider)/start", body: OAuthOptions(calendarAccess: calendarAccess))
    }

    func waitForOAuth(_ connection: OAuthStart, expectedAccountID: UUID? = nil) async throws {
        let requestGeneration = generation
        let expectedEmail = expectedAccountID.flatMap { id in accounts.first(where: { $0.id == id })?.email }
        while Date.now < connection.expiresAt {
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw BackendError.notConnected }
            let status: OAuthStatus = try await request("GET", "/v1/mail/oauth/connections/\(connection.connectionId.uuidString)")
            if ["connected", "complete", "completed"].contains(status.status) {
                guard let connectedID = status.accountId else { throw BackendError.invalidResponse }
                try await refreshAccounts()
                guard requestGeneration == generation else { throw BackendError.notConnected }
                if let expectedAccountID, connectedID != expectedAccountID {
                    throw BackendError.response(409, "A different email account was connected. To reconnect \(expectedEmail ?? "the selected account"), choose that account in the browser.")
                }
                return
            }
            if ["failed", "expired"].contains(status.status) { throw BackendError.response(400, "Account connection did not complete. Start again.") }
            try await Task.sleep(for: .seconds(2))
        }
        throw BackendError.response(400, "The account connection expired. Start again.")
    }

    func request<Response: Decodable & Sendable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                                 as: Response.Type = Response.self) async throws -> Response {
        guard let credential, let transport else { throw BackendError.notConnected }
        let requestGeneration = generation
        do {
            let response: Response = try await transport.request(method, path, token: credential.token, query: query)
            guard requestGeneration == generation else { throw BackendError.notConnected }
            return response
        } catch { await invalidateExpiredSession(error, generation: requestGeneration); throw error }
    }

    func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ method: String, _ path: String,
                            body: Body, as: Response.Type = Response.self) async throws -> Response {
        guard let credential, let transport else { throw BackendError.notConnected }
        let requestGeneration = generation
        do {
            let response: Response = try await transport.request(method, path, token: credential.token, body: body)
            guard requestGeneration == generation else { throw BackendError.notConnected }
            return response
        } catch { await invalidateExpiredSession(error, generation: requestGeneration); throw error }
    }

    func bytes(_ path: String) async throws -> Data {
        guard let credential, let transport else { throw BackendError.notConnected }
        let requestGeneration = generation
        do {
            let data = try await transport.raw("GET", path, token: credential.token)
            guard requestGeneration == generation else { throw BackendError.notConnected }
            return data
        } catch { await invalidateExpiredSession(error, generation: requestGeneration); throw error }
    }

    private func invalidateExpiredSession(_ error: Error, generation requestGeneration: UUID) async {
        guard requestGeneration == generation, case BackendError.response(401, _) = error else { return }
        let previousBusy = isBusy
        isBusy = true
        defer { isBusy = previousBusy }
        clearSession()
        let cleanupGeneration = generation
        do {
            try await storage.delete()
            if cleanupGeneration == generation { errorMessage = "Your workspace session ended. Sign in again to continue." }
        } catch {
            if cleanupGeneration == generation { errorMessage = "Your workspace session ended, but its saved Keychain token could not be removed. Sign in again to replace it." }
        }
    }
}
