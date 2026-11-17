import Foundation

actor SessionFixtureGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
}

actor SessionMemoryStore: BackendCredentialStorage {
    private(set) var value: BackendCredential?
    private(set) var saves = 0
    private(set) var deletions = 0
    private var loadGate: SessionFixtureGate?
    private var saveGate: SessionFixtureGate?
    private var deleteGate: SessionFixtureGate?
    init(_ value: BackendCredential? = nil) { self.value = value }
    func pauseNextLoad(_ gate: SessionFixtureGate) { loadGate = gate }
    func pauseNextSave(_ gate: SessionFixtureGate) { saveGate = gate }
    func pauseNextDelete(_ gate: SessionFixtureGate) { deleteGate = gate }
    func load() async throws -> BackendCredential? {
        let captured = value
        if let gate = loadGate { loadGate = nil; await gate.pause() }
        return captured
    }
    func save(_ credential: BackendCredential) async throws {
        if let gate = saveGate { saveGate = nil; await gate.pause() }
        value = credential; saves += 1
    }
    func delete() async throws {
        deletions += 1
        if let gate = deleteGate { deleteGate = nil; await gate.pause() }
        value = nil
    }
}

nonisolated final class SessionFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, SessionFixtureProtocol) -> Void)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler(request, self) }
    override func stopLoading() {}
    func respond(_ status: Int, _ data: Data = Data()) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    func failOffline() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
}

/// The fixture is handed off after startLoading returns; tests deliver one
/// completion on the main actor. URLProtocol itself is an Objective-C type.
nonisolated struct SessionResponseHandle: @unchecked Sendable {
    let fixture: SessionFixtureProtocol
    func respond(_ status: Int, _ data: Data) { fixture.respond(status, data) }
}

nonisolated struct SessionPersona: Sendable {
    let user = UUID()
    let workspace = UUID()
    let session = UUID()
    let account = UUID()
    let token = UUID().uuidString
    let email: String
    let base = "https://postmere.example.com"
    init(_ email: String) { self.email = email }
    var credential: BackendCredential { BackendCredential(baseURL: base, token: token, expiresAt: .now.addingTimeInterval(3600), userID: user, workspaceID: workspace) }
    var login: Data {
        encode(["token": token, "expires_at": timestamp(.now.addingTimeInterval(3600)),
                "absolute_expires_at": timestamp(.now.addingTimeInterval(86400)),
                "session_id": session.uuidString, "user_id": user.uuidString,
                "workspace_id": workspace.uuidString, "role": "owner"])
    }
    var me: Data { encode(["session_id": session.uuidString, "user_id": user.uuidString, "workspace_id": workspace.uuidString, "role": "owner", "email": email]) }
    var accounts: Data { encode([["id": account.uuidString, "provider": "gmail", "email": email, "display_name": "Fixture", "status": "connected", "last_synced_at": NSNull()]]) }
    func serve(_ request: URLRequest, _ fixture: SessionFixtureProtocol) {
        switch request.url!.path {
        case "/v1/auth/login": fixture.respond(200, login)
        case "/v1/auth/me": fixture.respond(200, me)
        case "/v1/mail/accounts": fixture.respond(200, accounts)
        case "/v1/auth/logout": fixture.respond(204)
        default: fixture.respond(200, Data("{}".utf8))
        }
    }
    private func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func encode(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
}

nonisolated struct SessionFixtureFailure: Error, CustomStringConvertible { let description: String }

@main
struct BackendSessionFixtures {
    @MainActor static var failures: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
    static func fixture(_ storage: SessionMemoryStore) -> BackendSession {
        RemoteAccountRegistry.accounts = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionFixtureProtocol.self]
        let result = BackendSession(storage: storage, configuration: config)
        result.baseURL = "https://postmere.example.com"
        return result
    }
    static func install(_ person: SessionPersona) { SessionFixtureProtocol.handler = { request, fixture in person.serve(request, fixture) } }
    static func login(_ session: BackendSession, _ person: SessionPersona) async {
        await session.login(email: person.email, password: "fixture password only", workspaceID: person.workspace.uuidString)
    }
    static func progress(_ text: String) { FileHandle.standardError.write(Data("\(text)\n".utf8)) }

    @MainActor static func main() async throws {
        let oldDefault = UserDefaults.standard.object(forKey: "postmereServerURL")
        defer {
            if let oldDefault { UserDefaults.standard.set(oldDefault, forKey: "postmereServerURL") }
            else { UserDefaults.standard.removeObject(forKey: "postmereServerURL") }
            RemoteAccountRegistry.accounts = []
        }
        progress("Checking login and restoration identities")
        await identities()
        progress("Checking expired-session cleanup and offline logout")
        await cleanup()
        progress("Checking many-account identity, reconnect and disconnect isolation")
        await manyAccounts()
        progress("Checking stale network and credential-store responses")
        await races()
        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            throw SessionFixtureFailure(description: "\(failures.count) backend session checks failed")
        }
        print("PASS: login/me identity, restoration, workspace mismatch, expiry, 401 removal and offline logout")
        print("PASS: paused deletion blocks new login; stale network, restore and save responses cannot install or erase another scope")
        print("PASS: 32 account identities, repeated additions, reconnect status, independent disconnect, duplicate-ID rejection and stale-list isolation")
        print("PASS: all credentials in memory and all HTTP requests mocked; no Keychain or real server accessed")
    }

    static func identities() async {
        let person = SessionPersona("owner@example.test")
        let store = SessionMemoryStore(); let session = fixture(store); install(person)
        await login(session, person)
        let saved = await store.value
        check(session.isConnected && !session.isBusy, "Successful login did not install a usable session")
        check(saved?.userID == person.user && saved?.workspaceID == person.workspace && saved?.token == person.token, "Login stored the wrong identity")
        check(RemoteAccountRegistry.accounts.count == 1 && RemoteAccountRegistry.accounts[0].accountID == person.account, "Login registry did not install the connected provider account")
        check(session.scope?.contains(person.workspace.uuidString.lowercased()) == true && session.scope?.contains(person.user.uuidString.lowercased()) == true, "Cache scope is missing user/workspace identity")
        check(RemoteAccountRegistry.accounts.first?.localID.hasPrefix("remote:\(session.scope ?? "missing"):") == true, "Provider identity is not scoped to the active session")

        let restoredStore = SessionMemoryStore(person.credential); let restored = fixture(restoredStore); install(person)
        await restored.restore()
        check(restored.credential?.token == person.token && restored.accounts.count == 1, "Valid saved identity was not restored")

        let wrong = SessionPersona("other@example.test")
        let mismatchStore = SessionMemoryStore(person.credential); let mismatch = fixture(mismatchStore); install(wrong)
        await mismatch.restore()
        let mismatchSaved = await mismatchStore.value
        check(!mismatch.isConnected && mismatchSaved == nil && RemoteAccountRegistry.accounts.isEmpty, "Restore identity mismatch left a saved or visible session")

        let deniedStore = SessionMemoryStore(person.credential); let denied = fixture(deniedStore)
        SessionFixtureProtocol.handler = { _, fixture in fixture.respond(401, Data("{}".utf8)) }
        await denied.restore()
        let deniedSaved = await deniedStore.value
        check(!denied.isConnected && deniedSaved == nil, "401 during restoration did not delete the rejected credential")

        let expired = BackendCredential(baseURL: person.base, token: person.token, expiresAt: .now.addingTimeInterval(-10), userID: person.user, workspaceID: person.workspace)
        let expiredStore = SessionMemoryStore(expired); let expiredSession = fixture(expiredStore)
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await expiredSession.restore()
        let expiredSaved = await expiredStore.value
        check(!expiredSession.isConnected && expiredSaved == nil && expiredSession.errorMessage == nil, "Expired local credential was not removed before network access")

        let badLoginStore = SessionMemoryStore(); let badLogin = fixture(badLoginStore); install(wrong)
        await login(badLogin, person)
        let badSaved = await badLoginStore.value
        check(!badLogin.isConnected && badSaved == nil, "Login accepted a different workspace than requested")

        let mismatchedMeStore = SessionMemoryStore(); let mismatchedMe = fixture(mismatchedMeStore)
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/auth/me" { fixture.respond(200, wrong.me) }
            else { person.serve(request, fixture) }
        }
        await login(mismatchedMe, person)
        let mismatchedSaved = await mismatchedMeStore.value
        check(!mismatchedMe.isConnected && mismatchedSaved == nil, "Login accepted a token whose /me identity did not match")
    }

    static func cleanup() async {
        let person = SessionPersona("owner@example.test"); let next = SessionPersona("next@example.test")
        let store = SessionMemoryStore(); let session = fixture(store); install(person); await login(session, person)
        let gate = SessionFixtureGate(); await store.pauseNextDelete(gate)
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/test/expired" { fixture.respond(401, Data("{}".utf8)) }
            else { person.serve(request, fixture) }
        }
        let expired = Task { let _: BackendEmpty? = try? await session.request("GET", "/v1/test/expired") }
        await gate.waitUntilEntered()
        check(!session.isConnected && RemoteAccountRegistry.accounts.isEmpty && session.isBusy, "401 did not clear identity before awaiting deletion")
        install(next); await login(session, next)
        check(!session.isConnected, "New login overtook pending credential deletion")
        await gate.release(); await expired.value
        await login(session, next)
        let nextSaved = await store.value
        check(session.credential?.userID == next.user && nextSaved?.token == next.token, "Old deletion erased the next login")

        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/auth/logout" { fixture.failOffline() }
            else { next.serve(request, fixture) }
        }
        await session.logout()
        let loggedOut = await store.value
        check(!session.isConnected && loggedOut == nil && RemoteAccountRegistry.accounts.isEmpty, "Offline logout retained local credentials or account registry")
        check(session.errorMessage?.contains("may remain active") == true && !session.isBusy, "Offline logout did not distinguish local removal from unconfirmed server revocation")
    }

    static func accountData(_ accounts: [BackendAccount]) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(accounts)
    }

    static func manyAccounts() async {
        let person = SessionPersona("many@example.test")
        let storage = SessionMemoryStore(); let session = fixture(storage)
        let rows = (0..<32).map { index in
            BackendAccount(id: UUID(), provider: index.isMultiple(of: 2) ? "gmail" : "microsoft",
                email: index < 2 ? "shared@example.test" : "mail\(index)@example.test",
                displayName: "Account \(index)", status: index == 3 ? "reconnect_required" : "connected", lastSyncedAt: nil)
        }
        let data = accountData(rows)
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/mail/accounts" { fixture.respond(200, data) }
            else { person.serve(request, fixture) }
        }
        await login(session, person)
        let originalScope = session.scope!
        let localIDs = Dictionary(uniqueKeysWithValues: RemoteAccountRegistry.accounts.map { ($0.accountID, $0.localID) })
        check(session.accounts.count == 32 && RemoteAccountRegistry.accounts.count == 32 && localIDs.count == 32, "Account list was capped or merged by provider/email")
        check(localIDs[rows[0].id] != localIDs[rows[1].id], "Matching email addresses across providers shared a local identity")
        check(session.isAccountConnected(rows[0].id, scope: originalScope), "Connected account was unavailable")
        check(!session.isAccountConnected(rows[3].id, scope: originalScope), "Reconnect-required account was treated as connected")
        check(!session.isAccountConnected(rows[0].id, scope: "another-workspace"), "Account was available in the wrong scope")
        check(RemoteAccountRegistry.accounts.first(where: { $0.accountID == rows[3].id })?.status == "reconnect_required", "Account status was lost in the registry")

        let reversed = accountData(Array(rows.reversed()))
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/mail/accounts" { fixture.respond(200, reversed) }
            else { person.serve(request, fixture) }
        }
        try! await session.refreshAccounts()
        check(Dictionary(uniqueKeysWithValues: RemoteAccountRegistry.accounts.map { ($0.accountID, $0.localID) }) == localIDs, "Reordered accounts changed cache identities")

        // A pre-disconnect account-list response must not reinstall the removed
        // account or disturb the other 31 accounts when it completes late.
        let victim = rows[7].id
        let (stream, continuation) = AsyncStream.makeStream(of: SessionResponseHandle.self, bufferingPolicy: .bufferingNewest(1))
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/mail/accounts" { continuation.yield(SessionResponseHandle(fixture: fixture)) }
            else if request.httpMethod == "DELETE" && request.url?.path == "/v1/mail/accounts/\(victim.uuidString)" { fixture.respond(204) }
            else { person.serve(request, fixture) }
        }
        let pending = Task { try! await session.refreshAccounts() }
        var iterator = stream.makeAsyncIterator(); let held = await iterator.next()!
        try! await session.disconnectAccount(id: victim)
        held.respond(200, data); continuation.finish(); await pending.value
        check(session.accounts.count == 31 && !session.accounts.contains(where: { $0.id == victim }), "Stale account list reinstalled a disconnected account")
        check(RemoteAccountRegistry.accounts.count == 31 && RemoteAccountRegistry.accounts.allSatisfy { $0.localID == localIDs[$0.accountID] }, "Disconnect changed another account's identity")
        check(session.disconnectingAccountIDs.isEmpty, "Successful disconnect remained busy")

        SessionFixtureProtocol.handler = { request, fixture in
            if request.httpMethod == "DELETE" { fixture.respond(500, Data("{}".utf8)) }
            else { person.serve(request, fixture) }
        }
        do { try await session.disconnectAccount(id: rows[0].id); check(false, "Failed disconnect reported success") }
        catch { }
        check(session.accounts.count == 31 && session.disconnectingAccountIDs.isEmpty, "Failed disconnect removed an account or remained busy")
        let duplicate = accountData([rows[0], rows[0]])
        SessionFixtureProtocol.handler = { _, fixture in fixture.respond(200, duplicate) }
        do { try await session.refreshAccounts(); check(false, "Duplicate account IDs accepted") }
        catch BackendError.invalidResponse { }
        catch { check(false, "Duplicate account IDs produced the wrong failure") }
        check(session.accounts.count == 31, "Invalid account list overwrote existing accounts")

        let added = BackendAccount(id: UUID(), provider: "gmail", email: "additional@example.test", displayName: nil, status: "connected", lastSyncedAt: nil)
        let updatedRows = rows.filter { $0.id != victim }.map { row in
            BackendAccount(id: row.id, provider: row.provider, email: row.email, displayName: row.displayName, status: "connected", lastSyncedAt: nil)
        } + [added]
        let updatedData = accountData(updatedRows)
        let connection = BackendSession.OAuthStart(connectionId: UUID(), authorizationUrl: "https://accounts.google.com/o/oauth2/v2/auth", expiresAt: .now.addingTimeInterval(300))
        let completion = try! JSONSerialization.data(withJSONObject: ["status": "connected", "account_id": rows[3].id.uuidString])
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/mail/accounts" { fixture.respond(200, updatedData) }
            else if request.url?.path == "/v1/mail/oauth/connections/\(connection.connectionId.uuidString)" { fixture.respond(200, completion) }
            else { person.serve(request, fixture) }
        }
        try! await session.waitForOAuth(connection, expectedAccountID: rows[3].id)
        check(session.accounts.count == 32 && session.isAccountConnected(rows[3].id, scope: originalScope), "Reconnect or adding another account failed")
        check(RemoteAccountRegistry.accounts.first(where: { $0.accountID == rows[3].id })?.localID == localIDs[rows[3].id], "Reconnect changed the existing account's cache identity")
        let wrongCompletion = try! JSONSerialization.data(withJSONObject: ["status": "connected", "account_id": added.id.uuidString])
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/mail/accounts" { fixture.respond(200, updatedData) }
            else if request.url?.path == "/v1/mail/oauth/connections/\(connection.connectionId.uuidString)" { fixture.respond(200, wrongCompletion) }
            else { person.serve(request, fixture) }
        }
        do { try await session.waitForOAuth(connection, expectedAccountID: rows[3].id); check(false, "Reconnect silently switched to a different account") }
        catch BackendError.response(409, _) { }
        catch { check(false, "Mismatched reconnect produced the wrong failure") }

        await session.logout()
        let other = SessionPersona("other-workspace@example.test")
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/mail/accounts" { fixture.respond(200, data) }
            else { other.serve(request, fixture) }
        }
        await login(session, other)
        check(session.accounts.count == 32 && session.scope != originalScope, "Second workspace did not install its account list")
        check(RemoteAccountRegistry.accounts.allSatisfy { $0.localID != localIDs[$0.accountID] }, "Reused provider account IDs collided across workspaces")
    }

    static func races() async {
        let old = SessionPersona("old@example.test"); let new = SessionPersona("new@example.test")
        let store = SessionMemoryStore(); let session = fixture(store); install(old); await login(session, old)
        let (stream, continuation) = AsyncStream.makeStream(of: SessionResponseHandle.self, bufferingPolicy: .bufferingNewest(1))
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/test/slow" { continuation.yield(SessionResponseHandle(fixture: fixture)) }
            else { old.serve(request, fixture) }
        }
        let pending = Task { let _: BackendEmpty? = try? await session.request("GET", "/v1/test/slow") }
        var iterator = stream.makeAsyncIterator(); let held = await iterator.next()!
        await session.logout(); install(new); await login(session, new)
        held.respond(401, Data("{}".utf8)); continuation.finish(); await pending.value
        let afterLate401 = await store.value
        check(session.credential?.userID == new.user && afterLate401?.token == new.token, "A previous scope's delayed 401 deleted the new session")
        check(RemoteAccountRegistry.accounts.first?.accountID == new.account, "A previous scope's response replaced the account registry")

        let staleStore = SessionMemoryStore(); let staleLogin = fixture(staleStore)
        let (loginStream, loginContinuation) = AsyncStream.makeStream(of: SessionResponseHandle.self, bufferingPolicy: .bufferingNewest(1))
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/auth/login" { loginContinuation.yield(SessionResponseHandle(fixture: fixture)) }
            else { old.serve(request, fixture) }
        }
        let loginTask = Task { await login(staleLogin, old) }
        var loginIterator = loginStream.makeAsyncIterator(); let heldLogin = await loginIterator.next()!
        staleLogin.clearSession(); heldLogin.respond(200, old.login); loginContinuation.finish(); await loginTask.value
        let afterStaleLogin = await staleStore.value
        check(!staleLogin.isConnected && afterStaleLogin == nil && RemoteAccountRegistry.accounts.isEmpty, "A cancelled login response installed credentials")

        let saveStore = SessionMemoryStore(); let saveSession = fixture(saveStore); let saveGate = SessionFixtureGate(); await saveStore.pauseNextSave(saveGate); install(old)
        let saving = Task { await login(saveSession, old) }; await saveGate.waitUntilEntered(); saveSession.clearSession(); await saveGate.release(); await saving.value
        let afterStaleSave = await saveStore.value
        check(!saveSession.isConnected && afterStaleSave == nil, "A stale credential save survived session invalidation")

        let loadStore = SessionMemoryStore(old.credential); let loadSession = fixture(loadStore); let loadGate = SessionFixtureGate(); await loadStore.pauseNextLoad(loadGate); install(old)
        let loading = Task { await loadSession.restore() }; await loadGate.waitUntilEntered(); loadSession.clearSession(); await loadGate.release(); await loading.value
        check(!loadSession.isConnected && RemoteAccountRegistry.accounts.isEmpty, "A stale storage load restored a cleared session")
    }
}
