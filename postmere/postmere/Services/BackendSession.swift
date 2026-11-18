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
    private(set) var isRestoring = false
    private(set) var isWaitingForSavedSession = false
    var isWaitingForSignOut: Bool { preferences.bool(forKey: "postmerePendingSignOut.v1") }
    var errorMessage: String?
    var statusMessage: String?
    var baseURL: String
    @ObservationIgnored private let storage: any BackendCredentialStorage
    @ObservationIgnored private let configuration: URLSessionConfiguration
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var transport: BackendHTTPClient?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var accountsGeneration = UUID()
    @ObservationIgnored var onAccountCatalogChanged: (() -> Void)?
    @ObservationIgnored var pushInstallationID: UUID?
    @ObservationIgnored private var isCheckingLifetime = false
    @ObservationIgnored private var lastLifetimeCheck = Date.distantPast
    @ObservationIgnored private var isRetryingRevocations = false
    @ObservationIgnored private var lastRevocationAttempt = Date.distantPast
    @ObservationIgnored private var savedSessionRetryAt = Date.distantFuture
    @ObservationIgnored private var savedSessionFailures = 0
    var isConnected: Bool { credential != nil }
    /// Credentials are installed only after the server verifies their identity.
    /// A saved token or an in-progress restore must never unlock the workspace.
    var canAccessWorkspace: Bool {
        guard !isRestoring, let credential else { return false }
        return credential.isValid(at: .now)
    }
    var realtimeGeneration: UUID? { canAccessWorkspace ? generation : nil }

    nonisolated struct Login: Encodable, Sendable { let email: String; let password: String; let workspaceId: UUID }
    nonisolated struct Logout: Encodable, Sendable {
        let signedOutAt: Date?
        let revokeMcp: Bool
    }
    nonisolated struct SessionResponse: Decodable, Sendable {
        let token: String
        let expiresAt: Date?
        let absoluteExpiresAt: Date?
        let sessionId: UUID
        let userId: UUID
        let workspaceId: UUID
        let role: String
        let persistent: Bool?
    }
    nonisolated struct Me: Decodable, Sendable {
        let sessionId: UUID; let userId: UUID; let workspaceId: UUID; let role: String; let email: String
        let expiresAt: Date?; let absoluteExpiresAt: Date?; let persistent: Bool?
    }
    nonisolated struct OAuthStart: Decodable, Sendable {
        let connectionId: UUID; let authorizationUrl: String; let expiresAt: Date
    }
    nonisolated struct OAuthStatus: Decodable, Sendable {
        let status: String; let accountId: UUID?; let error: String?
    }

    init(storage: (any BackendCredentialStorage)? = nil, configuration: URLSessionConfiguration = .ephemeral, preferences: UserDefaults = .standard) {
        self.storage = storage ?? BackendKeychain()
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.preferences = preferences
        baseURL = preferences.string(forKey: "postmereServerURL") ?? ""
    }

    func restore() async {
        guard credential == nil, !isBusy else { return }
        if isWaitingForSignOut { await logout(); return }
        // A persisted Focus catalog is descriptive metadata, not proof that the
        // saved workspace session is still valid. Rebuild it after verification.
        let previousFailures = savedSessionFailures
        clearSession()
        savedSessionFailures = previousFailures
        isBusy = true
        isRestoring = true
        defer { isRestoring = false; isBusy = false }
        let requestGeneration = generation
        var savedWasLoaded = false
        do {
            guard let saved = try await storage.load() else { return }
            savedWasLoaded = true
            guard requestGeneration == generation else { return }
            // Logout intent wins even if deleting the ordinary Keychain item
            // failed. Pending tokens are retained only for server revocation.
            let pending = try await storage.pendingRevocations()
            guard requestGeneration == generation else { return }
            if pending.contains(where: { $0.credential.token == saved.token && $0.credential.baseURL == saved.baseURL }) {
                try await storage.delete()
                return
            }
            let client = try BackendHTTPClient(baseURL: saved.baseURL, configuration: configuration)
            let me: Me = try await client.request("GET", "/v1/auth/me", token: saved.token)
            guard requestGeneration == generation else { return }
            guard me.userId == saved.userID, me.workspaceId == saved.workspaceID,
                  ["owner", "admin", "member"].contains(me.role) else {
                try await storage.delete()
                throw BackendError.notConnected
            }
            let verified = try canonicalCredential(saved, me: me)
            guard verified.isValid(at: .now) else {
                try await storage.delete()
                throw BackendError.notConnected
            }
            if verified != saved {
                guard try await storage.replace(verified, matchingToken: saved.token) else { throw BackendError.notConnected }
                guard requestGeneration == generation else { return }
            }
            credential = verified
            baseURL = saved.baseURL
            transport = client
            lastLifetimeCheck = .now
            savedSessionFailures = 0
            errorMessage = nil
            statusMessage = nil
            try await refreshAccounts()
        } catch {
            if requestGeneration == generation {
                if case BackendError.response(401, _) = error { try? await storage.delete() }
                guard requestGeneration == generation else { return }
                errorMessage = error.localizedDescription
                if savedWasLoaded, credential == nil, Self.retryableVerification(error) { scheduleSavedSessionRetry() }
            }
        }
    }

    func login(email: String, password: String, workspaceID: String) async {
        guard !isBusy, !isWaitingForSignOut, credential == nil else { return }
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
            guard response.workspaceId == workspace,
                  Self.validLifetime(expiresAt: response.expiresAt, absoluteExpiresAt: response.absoluteExpiresAt), !response.token.isEmpty,
                  response.persistent.map({ $0 == (response.expiresAt == nil) }) != false,
                  ["owner", "admin", "member"].contains(response.role) else { throw BackendError.invalidResponse }
            let issuedCredential = BackendCredential(baseURL: client.baseURL.absoluteString, token: response.token,
                expiresAt: response.expiresAt, userID: response.userId, workspaceID: response.workspaceId, absoluteExpiresAt: response.absoluteExpiresAt)
            guard issuedCredential.isValid(at: .now) else { throw BackendError.invalidResponse }
            let me: Me = try await client.request("GET", "/v1/auth/me", token: response.token)
            guard requestGeneration == generation else { throw BackendError.notConnected }
            guard me.userId == response.userId, me.workspaceId == workspace,
                  me.sessionId == response.sessionId, me.role == response.role,
                  me.email.caseInsensitiveCompare(loginEmail) == .orderedSame else { throw BackendError.invalidResponse }
            let saved = try canonicalCredential(issuedCredential, me: me)
            guard saved.isValid(at: .now) else { throw BackendError.invalidResponse }
            try await storage.save(saved)
            savedToken = true
            guard requestGeneration == generation, saved.isValid(at: .now) else { throw BackendError.notConnected }
            credential = saved
            transport = client
            lastLifetimeCheck = .now
            preferences.set(saved.baseURL, forKey: "postmereServerURL")
            // The session is installed. A later account-list failure should not
            // revoke a valid session; 401 handling clears it independently.
            issued = nil
            try await refreshAccounts()
            guard requestGeneration == generation else { return }
            statusMessage = "Connected to your Postmere workspace."
        } catch {
            if let (client, token) = issued {
                if savedToken { try? await storage.delete() }
                let _: BackendEmpty? = try? await client.request("POST", "/v1/auth/logout", token: token,
                    body: Logout(signedOutAt: nil, revokeMcp: false))
            }
            if requestGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    func logout() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let activeCredential = credential
        let activeClient = transport
        let requestedAt = isWaitingForSignOut
            ? preferences.object(forKey: "postmerePendingSignOutDate.v1") as? Date : Date.now
        // Invalidate pending mail/restore responses before either storage or
        // network operations suspend. Session transitions remain busy until the
        // old credential deletion has finished, so it cannot delete a new login.
        clearSession()
        let requestGeneration = generation
        preferences.set(true, forKey: "postmerePendingSignOut.v1")
        if let requestedAt { preferences.set(requestedAt, forKey: "postmerePendingSignOutDate.v1") }
        // A failed startup verification leaves the token in Keychain while the
        // workspace stays locked. Signing out must revoke that saved session
        // too, otherwise its persistent push delivery would outlive this Mac.
        let saved: BackendCredential?
        do {
            if let activeCredential { saved = activeCredential }
            else { saved = try await storage.load() }
        }
        catch {
            scheduleSignOutRetry()
            errorMessage = "Could not read the saved Keychain session for sign-out. Try signing out again."
            return
        }
        let client = activeClient ?? saved.flatMap { try? BackendHTTPClient(baseURL: $0.baseURL, configuration: configuration) }
        let pending = saved.map { BackendPendingRevocation(id: UUID(), credential: $0, pushInstallationID: pushInstallationID, requestedAt: requestedAt) }
        var queueError: Error?
        if let pending {
            do { try await storage.enqueueRevocation(pending) } catch { queueError = error }
        }
        var deletionError: Error?
        // If the encrypted retry job could not be written, retain the ordinary
        // Keychain token until the server confirms revocation. The nonsecret
        // sign-out marker prevents restore from treating it as a login.
        if queueError == nil {
            do { try await storage.delete() } catch { deletionError = error }
        } else { deletionError = queueError }
        var revocationError: Error? = saved != nil && client == nil ? BackendError.invalidURL : nil
        if let saved, let client {
            if let pushInstallationID {
                // Use the captured old session after the local workspace has
                // already locked. A successful logout also invalidates delivery
                // server-side if this best-effort device removal fails.
                let _: BackendEmpty? = try? await client.request("DELETE", "/v1/push/devices/\(pushInstallationID.uuidString)", token: saved.token)
            }
            do {
                let _: BackendEmpty = try await client.request("POST", "/v1/auth/logout", token: saved.token,
                    body: Logout(signedOutAt: requestedAt, revokeMcp: requestedAt != nil))
            }
            catch BackendError.response(401, _) { /* Already revoked. */ }
            catch { revocationError = error }
            if revocationError == nil, let pending { try? await storage.removeRevocation(id: pending.id) }
            if revocationError == nil, queueError != nil {
                do { try await storage.delete(); deletionError = nil } catch { deletionError = error }
            }
        }
        guard requestGeneration == generation else { return }
        if queueError == nil || (deletionError == nil && revocationError == nil) {
            preferences.removeObject(forKey: "postmerePendingSignOut.v1")
            preferences.removeObject(forKey: "postmerePendingSignOutDate.v1")
        } else { scheduleSignOutRetry() }
        if deletionError == nil {
            statusMessage = "Signed out on this Mac."
            if revocationError == nil { errorMessage = nil }
            else if queueError == nil {
                errorMessage = "Server sign-out is pending and will retry when Postmere can reconnect. This Mac is signed out, but the server session may remain active until revocation is confirmed."
            } else {
                errorMessage = "This Mac is signed out, but server revocation failed and could not be saved for retry. Revoke the session from your workspace before trusting that server access has ended."
            }
        } else {
            statusMessage = "Signed out of this open window."
            errorMessage = "Could not remove the saved Keychain session. Sign-out is saved and this session will not be restored; try signing out again."
        }
    }

    func clearSession() {
        generation = UUID()
        credential = nil
        transport = nil
        isRestoring = false
        lastLifetimeCheck = .distantPast
        isWaitingForSavedSession = false
        savedSessionRetryAt = .distantFuture
        savedSessionFailures = 0
        accountsGeneration = UUID()
        accounts = []
        disconnectingAccountIDs = []
        RemoteAccountRegistry.accounts = []
        preferences.removeObject(forKey: "postmereFocusAccountCatalog.v1")
        onAccountCatalogChanged?()
    }

    /// Persistent sessions have no local age limit. For a legacy bounded token,
    /// ask the server before trusting its old cached deadline: deployment may
    /// have upgraded that same still-active token to a persistent session.
    func expireSessionIfNeeded(now: Date = .now, force: Bool = false) async {
        guard !isBusy, !isCheckingLifetime, let credential, let transport,
              credential.expiresAt != nil || credential.absoluteExpiresAt != nil,
              force || !credential.isValid(at: now) || now.timeIntervalSince(lastLifetimeCheck) >= 60,
              force || !isWaitingForSavedSession || now >= savedSessionRetryAt else { return }
        let requestGeneration = generation
        let needsVerificationGate = !credential.isValid(at: now)
        isCheckingLifetime = true
        lastLifetimeCheck = now
        if needsVerificationGate { isRestoring = true; onAccountCatalogChanged?() }
        defer {
            isCheckingLifetime = false
            if requestGeneration == generation, needsVerificationGate { isRestoring = false; onAccountCatalogChanged?() }
        }
        do {
            let me: Me = try await transport.request("GET", "/v1/auth/me", token: credential.token)
            guard requestGeneration == generation else { return }
            guard me.userId == credential.userID, me.workspaceId == credential.workspaceID,
                  ["owner", "admin", "member"].contains(me.role) else {
                await invalidateSession(generation: requestGeneration)
                return
            }
            let verified = try canonicalCredential(credential, me: me)
            guard verified.isValid(at: now) else {
                await invalidateSession(generation: requestGeneration)
                return
            }
            if verified != credential {
                let replaced = try await storage.replace(verified, matchingToken: credential.token)
                guard requestGeneration == generation else { return }
                guard replaced else { clearSession(); return }
                self.credential = verified
                onAccountCatalogChanged?()
            }
            isWaitingForSavedSession = false
            savedSessionFailures = 0
            savedSessionRetryAt = .distantFuture
            if needsVerificationGate { errorMessage = nil; statusMessage = nil }
        } catch {
            await invalidateExpiredSession(error, generation: requestGeneration)
            // A network outage is not proof that the server revoked a token.
            // Keep it in Keychain so an upgraded session can validate later.
            if requestGeneration == generation, !credential.isValid(at: now) {
                errorMessage = "Could not verify your saved sign-in. Postmere will retry when the connection returns."
                if Self.retryableVerification(error) { scheduleSavedSessionRetry(now: now) }
            }
        }
    }

    func retrySavedSession(now: Date = .now, force: Bool = false) async {
        guard !isBusy, isWaitingForSavedSession, force || now >= savedSessionRetryAt else { return }
        if isWaitingForSignOut { await logout(); return }
        if credential == nil { await restore() }
        else { await expireSessionIfNeeded(now: now, force: true) }
    }

    private func scheduleSavedSessionRetry(now: Date = .now) {
        isWaitingForSavedSession = true
        savedSessionRetryAt = now.addingTimeInterval(min(60, 5 * pow(2, Double(min(savedSessionFailures, 4)))))
        savedSessionFailures = min(savedSessionFailures + 1, 4)
        statusMessage = "Waiting to reconnect. Your saved sign-in will be checked automatically."
    }

    private func scheduleSignOutRetry() {
        scheduleSavedSessionRetry()
        statusMessage = "Sign-out is pending. Postmere will retry without restoring your session."
    }

    private static func retryableVerification(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case let BackendError.response(code, _) = error { return code == 408 || code == 429 || code >= 500 }
        return false
    }

    private static func validLifetime(expiresAt: Date?, absoluteExpiresAt: Date?) -> Bool {
        switch (expiresAt, absoluteExpiresAt) {
        case (nil, nil): true
        case let (expires?, absolute?): expires <= absolute
        default: false
        }
    }

    private func canonicalCredential(_ saved: BackendCredential, me: Me) throws -> BackendCredential {
        guard let persistent = me.persistent else {
            // Older servers omitted lifetime metadata from /me. Retain their
            // existing bounded deadline; never infer persistence from absence.
            guard saved.expiresAt != nil else { throw BackendError.invalidResponse }
            return saved
        }
        guard Self.validLifetime(expiresAt: me.expiresAt, absoluteExpiresAt: me.absoluteExpiresAt),
              persistent == (me.expiresAt == nil) else { throw BackendError.invalidResponse }
        return BackendCredential(baseURL: saved.baseURL, token: saved.token, expiresAt: me.expiresAt,
                                 userID: saved.userID, workspaceID: saved.workspaceID, absoluteExpiresAt: me.absoluteExpiresAt)
    }

    /// Revocation jobs are separate from the active login and can never install
    /// credentials. Retrying one cannot clear a newer workspace session.
    func retryPendingRevocations(now: Date = .now, force: Bool = false) async {
        guard !isRetryingRevocations, force || now.timeIntervalSince(lastRevocationAttempt) >= 30 else { return }
        isRetryingRevocations = true
        lastRevocationAttempt = now
        defer { isRetryingRevocations = false }
        guard let pending = try? await storage.pendingRevocations() else { return }
        for item in pending {
            guard !Task.isCancelled else { return }
            do {
                let client = try BackendHTTPClient(baseURL: item.credential.baseURL, configuration: configuration)
                if let installation = item.pushInstallationID {
                    let _: BackendEmpty? = try? await client.request("DELETE", "/v1/push/devices/\(installation.uuidString)", token: item.credential.token)
                }
                do {
                    let _: BackendEmpty = try await client.request("POST", "/v1/auth/logout", token: item.credential.token,
                        body: Logout(signedOutAt: item.requestedAt, revokeMcp: item.requestedAt != nil))
                }
                catch BackendError.response(401, _) { /* Already revoked. */ }
                try await storage.removeRevocation(id: item.id)
            } catch { /* Keep encrypted intent for the next connection/launch. */ }
        }
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
        // Focus queries can run in a separate process. Persist only the account
        // catalog; bearer tokens and provider credentials never enter defaults.
        if let catalog = try? JSONEncoder().encode(RemoteAccountRegistry.accounts) {
            preferences.set(catalog, forKey: "postmereFocusAccountCatalog.v1")
        } else {
            preferences.removeObject(forKey: "postmereFocusAccountCatalog.v1")
        }
        onAccountCatalogChanged?()
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
                guard accounts.contains(where: { $0.id == connectedID }) else { throw BackendError.invalidResponse }
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

    func receiveEvents(lastEventID: String?,
                       receive: @escaping @MainActor @Sendable (BackendServerEvent) throws -> Void) async throws {
        guard canAccessWorkspace, let credential else { throw BackendError.notConnected }
        let requestGeneration = generation
        let stream = try BackendEventStream(baseURL: credential.baseURL, configuration: configuration)
        do {
            try await stream.consume(token: credential.token, lastEventID: lastEventID) { [weak self] event in
                guard let session = self else { throw CancellationError() }
                try await MainActor.run {
                    guard session.generation == requestGeneration, session.canAccessWorkspace else { throw CancellationError() }
                    try receive(event)
                }
            }
        } catch { await invalidateExpiredSession(error, generation: requestGeneration); throw error }
    }

    private func invalidateExpiredSession(_ error: Error, generation requestGeneration: UUID) async {
        guard requestGeneration == generation, case BackendError.response(401, _) = error else { return }
        await invalidateSession(generation: requestGeneration)
    }

    private func invalidateSession(generation requestGeneration: UUID) async {
        guard requestGeneration == generation else { return }
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
