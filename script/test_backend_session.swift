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
    private var replaceGate: SessionFixtureGate?
    private var failDeletion = false
    private var failLoad = false
    private var failRevocationSave = false
    private(set) var revocations: [BackendPendingRevocation] = []
    init(_ value: BackendCredential? = nil) { self.value = value }
    func pauseNextLoad(_ gate: SessionFixtureGate) { loadGate = gate }
    func pauseNextSave(_ gate: SessionFixtureGate) { saveGate = gate }
    func pauseNextDelete(_ gate: SessionFixtureGate) { deleteGate = gate }
    func pauseNextReplace(_ gate: SessionFixtureGate) { replaceGate = gate }
    func failNextDelete() { failDeletion = true }
    func failNextLoad() { failLoad = true }
    func failNextRevocationSave() { failRevocationSave = true }
    func load() async throws -> BackendCredential? {
        if failLoad { failLoad = false; throw URLError(.cannotOpenFile) }
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
        if failDeletion { failDeletion = false; throw URLError(.cannotWriteToFile) }
        value = nil
    }
    func replace(_ credential: BackendCredential, matchingToken: String) async throws -> Bool {
        if let gate = replaceGate { replaceGate = nil; await gate.pause() }
        guard let current = value, current.token == matchingToken, current.baseURL == credential.baseURL,
              current.userID == credential.userID, current.workspaceID == credential.workspaceID else { return false }
        value = credential; saves += 1
        return true
    }
    func pendingRevocations() -> [BackendPendingRevocation] { revocations }
    func enqueueRevocation(_ item: BackendPendingRevocation) throws {
        if failRevocationSave { failRevocationSave = false; throw URLError(.cannotWriteToFile) }
        revocations.append(item)
    }
    func removeRevocation(id: UUID) { revocations.removeAll { $0.id == id } }
}

nonisolated struct SessionRecordedRequest: Sendable {
    let path: String
    let body: Data
}

nonisolated final class SessionRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SessionRecordedRequest] = []
    var values: [SessionRecordedRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func record(_ request: URLRequest) {
        let body: Data
        if let value = request.httpBody { body = value }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = Data() }
        lock.lock(); defer { lock.unlock() }
        requests.append(SessionRecordedRequest(path: request.url?.path ?? "", body: body))
    }
}

nonisolated final class SessionFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, SessionFixtureProtocol) -> Void)!
    nonisolated(unsafe) static var recorder = SessionRequestRecorder()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.recorder.record(request); Self.handler(request, self) }
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
    let persistent: Bool
    init(_ email: String, persistent: Bool = false) { self.email = email; self.persistent = persistent }
    var credential: BackendCredential { BackendCredential(baseURL: base, token: token, expiresAt: persistent ? nil : .now.addingTimeInterval(3600), userID: user, workspaceID: workspace) }
    var login: Data {
        encode(["token": token, "expires_at": persistent ? NSNull() as Any : timestamp(.now.addingTimeInterval(3600)),
                "absolute_expires_at": persistent ? NSNull() as Any : timestamp(.now.addingTimeInterval(86400)), "persistent": persistent,
                "session_id": session.uuidString, "user_id": user.uuidString,
                "workspace_id": workspace.uuidString, "role": "owner"])
    }
    var me: Data {
        var value: [String: Any] = ["session_id": session.uuidString, "user_id": user.uuidString, "workspace_id": workspace.uuidString, "role": "owner", "email": email]
        if persistent { value.merge(["expires_at": NSNull(), "absolute_expires_at": NSNull(), "persistent": true]) { _, new in new } }
        return encode(value)
    }
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
    @MainActor static var preferenceSuites: [String] = []
    @MainActor static var preferencesBySession: [ObjectIdentifier: UserDefaults] = [:]
    static func catalog(_ session: BackendSession) -> [RemoteAccountIdentity] {
        guard let data = preferencesBySession[ObjectIdentifier(session)]?.data(forKey: "postmereFocusAccountCatalog.v1") else { return [] }
        return (try? JSONDecoder().decode([RemoteAccountIdentity].self, from: data)) ?? []
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
    static func fixture(_ storage: SessionMemoryStore) -> BackendSession {
        RemoteAccountRegistry.accounts = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionFixtureProtocol.self]
        let suite = "PostmereSessionChecks.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let preferences = UserDefaults(suiteName: suite)!
        let result = BackendSession(storage: storage, configuration: config, preferences: preferences)
        preferencesBySession[ObjectIdentifier(result)] = preferences
        result.baseURL = "https://postmere.example.com"
        return result
    }
    static func install(_ person: SessionPersona) { SessionFixtureProtocol.handler = { request, fixture in person.serve(request, fixture) } }
    static func login(_ session: BackendSession, _ person: SessionPersona) async {
        await session.login(email: person.email, password: "fixture password only", workspaceID: person.workspace.uuidString)
    }
    static func progress(_ text: String) { FileHandle.standardError.write(Data("\(text)\n".utf8)) }

    @MainActor static func main() async throws {
        defer {
            for suite in preferenceSuites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            preferencesBySession = [:]
            RemoteAccountRegistry.accounts = []
        }
        progress("Checking login and restoration identities")
        await identities()
        progress("Checking mandatory workspace access and restore loading")
        await workspaceAccess()
        progress("Checking expired-session cleanup and offline logout")
        await cleanup()
        progress("Checking persistent sessions, migration, reconnect and queued sign-out")
        await persistence()
        progress("Checking sign-out cutoff preservation for MCP revocation")
        await signOutCutoffs()
        progress("Checking many-account identity, reconnect and disconnect isolation")
        await manyAccounts()
        progress("Checking stale network and credential-store responses")
        await races()
        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            throw SessionFixtureFailure(description: "\(failures.count) backend session checks failed")
        }
        print("PASS: login/me identity, restoration, workspace mismatch, expiry, 401 removal and offline logout")
        print("PASS: workspace gate stays closed during restore, rejects missing/invalid/offline sessions, and closes before logout or expiry cleanup")
        print("PASS: paused deletion blocks new login; stale network, restore and save responses cannot install or erase another scope")
        print("PASS: 32 account identities, repeated additions, reconnect status, independent disconnect, duplicate-ID rejection and stale-list isolation")
        print("PASS: persistent lifetime, expired-cache migration, network/408 recovery, atomic upgrades and durable offline sign-out")
        print("PASS: original sign-out time survives retries/relaunch, legacy jobs omit MCP revocation, and rejected-login cleanup preserves MCP connections")
        print("PASS: all credentials in memory, preferences in isolated suites, and all HTTP requests mocked; no Keychain or real server accessed")
    }

    static func identities() async {
        let person = SessionPersona("owner@example.test")
        let store = SessionMemoryStore(); let session = fixture(store); install(person)
        await login(session, person)
        let saved = await store.value
        check(session.isConnected && session.canAccessWorkspace && !session.isBusy, "Successful verified login did not unlock the workspace")
        check(saved?.userID == person.user && saved?.workspaceID == person.workspace && saved?.token == person.token, "Login stored the wrong identity")
        check(RemoteAccountRegistry.accounts.count == 1 && RemoteAccountRegistry.accounts[0].accountID == person.account, "Login registry did not install the connected provider account")
        check(catalog(session).map(\.accountID) == [person.account], "Focus catalog did not persist the scoped connected account")
        check(preferencesBySession[ObjectIdentifier(session)]?.string(forKey: "postmereServerURL") == person.base, "Server URL was not saved in the injected preferences")
        check(session.scope?.contains(person.workspace.uuidString.lowercased()) == true && session.scope?.contains(person.user.uuidString.lowercased()) == true, "Cache scope is missing user/workspace identity")
        check(RemoteAccountRegistry.accounts.first?.localID.hasPrefix("remote:\(session.scope ?? "missing"):") == true, "Provider identity is not scoped to the active session")

        let restoredStore = SessionMemoryStore(person.credential); let restored = fixture(restoredStore); install(person)
        await restored.restore()
        check(restored.credential?.token == person.token && restored.accounts.count == 1 && restored.canAccessWorkspace && !restored.isRestoring,
              "Valid saved identity did not unlock the workspace after verification")

        let wrong = SessionPersona("other@example.test")
        let mismatchStore = SessionMemoryStore(person.credential); let mismatch = fixture(mismatchStore); install(wrong)
        await mismatch.restore()
        let mismatchSaved = await mismatchStore.value
        check(!mismatch.isConnected && !mismatch.canAccessWorkspace && !mismatch.isRestoring && mismatchSaved == nil && RemoteAccountRegistry.accounts.isEmpty,
              "Restore identity mismatch left a saved or accessible workspace")

        let deniedStore = SessionMemoryStore(person.credential); let denied = fixture(deniedStore)
        SessionFixtureProtocol.handler = { _, fixture in fixture.respond(401, Data("{}".utf8)) }
        await denied.restore()
        let deniedSaved = await deniedStore.value
        check(!denied.isConnected && !denied.canAccessWorkspace && !denied.isRestoring && deniedSaved == nil,
              "Revoked restoration did not close the workspace gate and delete its credential")

        let expired = BackendCredential(baseURL: person.base, token: person.token, expiresAt: .now.addingTimeInterval(-10), userID: person.user, workspaceID: person.workspace)
        let expiredStore = SessionMemoryStore(expired); let expiredSession = fixture(expiredStore)
        preferencesBySession[ObjectIdentifier(expiredSession)]?.set(Data("stale catalog".utf8), forKey: "postmereFocusAccountCatalog.v1")
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await expiredSession.restore()
        let expiredSaved = await expiredStore.value
        check(!expiredSession.isConnected && !expiredSession.canAccessWorkspace && !expiredSession.isRestoring && expiredSaved != nil && expiredSession.isWaitingForSavedSession,
              "Expired cached metadata was discarded before the server could verify a persistent upgrade")
        check(preferencesBySession[ObjectIdentifier(expiredSession)]?.data(forKey: "postmereFocusAccountCatalog.v1") == nil, "Expired restoration kept stale Focus metadata")

        let badLoginStore = SessionMemoryStore(); let badLogin = fixture(badLoginStore); install(wrong)
        await login(badLogin, person)
        let badSaved = await badLoginStore.value
        check(!badLogin.isConnected && !badLogin.canAccessWorkspace && badSaved == nil, "Login unlocked a different workspace than requested")

        let mismatchedMeStore = SessionMemoryStore(); let mismatchedMe = fixture(mismatchedMeStore)
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/auth/me" { fixture.respond(200, wrong.me) }
            else { person.serve(request, fixture) }
        }
        await login(mismatchedMe, person)
        let mismatchedSaved = await mismatchedMeStore.value
        check(!mismatchedMe.isConnected && !mismatchedMe.canAccessWorkspace && mismatchedSaved == nil,
              "Login unlocked a workspace whose /me identity did not match")
    }

    static func workspaceAccess() async {
        let person = SessionPersona("gated@example.test")
        let emptyStore = SessionMemoryStore(); let empty = fixture(emptyStore)
        let loadGate = SessionFixtureGate(); await emptyStore.pauseNextLoad(loadGate)
        check(!empty.canAccessWorkspace && !empty.isRestoring, "New session exposed a workspace before restoration")
        let loading = Task { await empty.restore() }
        await loadGate.waitUntilEntered()
        check(empty.isRestoring && empty.isBusy && !empty.canAccessWorkspace, "Saved-credential lookup did not expose the loading gate")
        await loadGate.release(); await loading.value
        check(!empty.canAccessWorkspace && !empty.isRestoring && !empty.isBusy, "Missing credentials left the gate unlocked or indefinitely loading")

        let verifiedStore = SessionMemoryStore(person.credential); let verified = fixture(verifiedStore)
        let (stream, continuation) = AsyncStream.makeStream(of: SessionResponseHandle.self, bufferingPolicy: .bufferingNewest(1))
        SessionFixtureProtocol.handler = { request, fixture in
            if ["/v1/auth/me", "/v1/mail/accounts"].contains(request.url?.path ?? "") {
                continuation.yield(SessionResponseHandle(fixture: fixture))
            } else { person.serve(request, fixture) }
        }
        let restoring = Task { await verified.restore() }
        var iterator = stream.makeAsyncIterator()
        let heldIdentity = await iterator.next()!
        check(verified.isRestoring && !verified.canAccessWorkspace && verified.credential == nil,
              "Saved credentials unlocked the workspace before /me verification")
        heldIdentity.respond(200, person.me)
        let heldAccounts = await iterator.next()!
        check(verified.isRestoring && !verified.canAccessWorkspace && verified.credential?.userID == person.user,
              "Restore stopped showing its loading gate before the initial account request completed")
        heldAccounts.respond(500, Data("{}".utf8)); continuation.finish(); await restoring.value
        check(verified.canAccessWorkspace && !verified.isRestoring && verified.errorMessage != nil,
              "A transient account-list failure revoked the already verified workspace")

        let logoutGate = SessionFixtureGate(); await verifiedStore.pauseNextDelete(logoutGate); install(person)
        let signingOut = Task { await verified.logout() }
        await logoutGate.waitUntilEntered()
        check(!verified.canAccessWorkspace && verified.credential == nil && RemoteAccountRegistry.accounts.isEmpty,
              "Logout left the workspace accessible while credential deletion was suspended")
        await logoutGate.release(); await signingOut.value

        let offlineStore = SessionMemoryStore(person.credential); let offline = fixture(offlineStore)
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await offline.restore()
        let offlineSaved = await offlineStore.value
        check(!offline.canAccessWorkspace && !offline.isRestoring && offline.credential == nil && offlineSaved != nil,
              "Unverified offline restoration unlocked the workspace or discarded a retryable saved credential")

        let revokedStore = SessionMemoryStore(person.credential); let revoked = fixture(revokedStore)
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/mail/accounts" { fixture.respond(401, Data("{}".utf8)) }
            else { person.serve(request, fixture) }
        }
        await revoked.restore()
        let revokedSaved = await revokedStore.value
        check(!revoked.canAccessWorkspace && !revoked.isRestoring && revoked.credential == nil && revokedSaved == nil,
              "Revocation during initial account loading unlocked the workspace")

        let rejectedStore = SessionMemoryStore(); let rejected = fixture(rejectedStore)
        SessionFixtureProtocol.handler = { _, fixture in fixture.respond(401, Data("{}".utf8)) }
        await login(rejected, person)
        check(!rejected.canAccessWorkspace && !rejected.isBusy && rejected.credential == nil,
              "Rejected sign-in unlocked the workspace")

        let expiryStore = SessionMemoryStore(); let expiry = fixture(expiryStore); install(person)
        await login(expiry, person)
        let expiration = expiry.credential!.expiresAt!
        await expiry.expireSessionIfNeeded(now: expiration.addingTimeInterval(-1))
        check(expiry.canAccessWorkspace, "Expiry check ended a session before its deadline")
        let expiryGate = SessionFixtureGate(); await expiryStore.pauseNextDelete(expiryGate)
        let expiring = Task { await expiry.expireSessionIfNeeded(now: expiration) }
        await expiryGate.waitUntilEntered()
        check(!expiry.canAccessWorkspace && expiry.credential == nil && RemoteAccountRegistry.accounts.isEmpty && expiry.isBusy,
              "Natural expiry left the workspace accessible while deleting its saved credential")
        await expiryGate.release(); await expiring.value
        let expiredSaved = await expiryStore.value
        check(expiredSaved == nil && !expiry.isBusy, "Natural expiry did not finish credential cleanup")
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
        check(catalog(session).isEmpty, "401 left a stale Focus account catalog")
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
        check(catalog(session).isEmpty, "Offline logout retained its Focus account catalog")
        check(session.errorMessage?.contains("may remain active") == true && !session.isBusy, "Offline logout did not distinguish local removal from unconfirmed server revocation")
    }

    static func persistence() async {
        let person = SessionPersona("persistent@example.test", persistent: true)
        let store = SessionMemoryStore(); let session = fixture(store); install(person)
        await login(session, person)
        let saved = await store.value
        let later = Date.now.addingTimeInterval(10 * 365 * 86400)
        check(saved?.expiresAt == nil && saved?.absoluteExpiresAt == nil && saved?.isValid(at: later) == true,
              "Persistent login was given a local expiry")
        let generation = session.realtimeGeneration
        await session.expireSessionIfNeeded(now: later, force: true)
        check(session.canAccessWorkspace && session.realtimeGeneration == generation,
              "Age alone ended a persistent workspace session")

        let old = BackendCredential(baseURL: person.base, token: person.token, expiresAt: .now.addingTimeInterval(-86400),
                                    userID: person.user, workspaceID: person.workspace)
        let upgradedStore = SessionMemoryStore(old); let upgraded = fixture(upgradedStore); install(person)
        await upgraded.restore()
        let upgradedSaved = await upgradedStore.value
        check(upgraded.canAccessWorkspace && upgradedSaved?.expiresAt == nil && upgradedSaved?.absoluteExpiresAt == nil,
              "Expired cached metadata prevented the server's persistent-session migration")
        let relaunched = fixture(upgradedStore); await relaunched.restore()
        check(relaunched.canAccessWorkspace && relaunched.credential?.isValid(at: later) == true,
              "Canonical persistent metadata did not survive relaunch")

        for response in [0, 408, 429, 503] {
            let retryStore = SessionMemoryStore(old); let retry = fixture(retryStore)
            SessionFixtureProtocol.handler = { _, fixture in
                if response == 0 { fixture.failOffline() }
                else { fixture.respond(response, Data("{}".utf8)) }
            }
            await retry.restore()
            let waitingSaved = await retryStore.value
            check(!retry.canAccessWorkspace && retry.isWaitingForSavedSession && waitingSaved?.token == person.token,
                  "Transient verification \(response) discarded the saved token or skipped automatic retry")
            install(person); await retry.retrySavedSession(force: true)
            check(retry.canAccessWorkspace && !retry.isWaitingForSavedSession && retry.errorMessage == nil,
                  "Transient verification \(response) did not recover without another password")
        }

        // Upgrade a running pre-migration session, then race a second upgrade
        // against sign-out/new sign-in while the storage compare-and-swap waits.
        var legacyMeObject = try! JSONSerialization.jsonObject(with: person.me) as! [String: Any]
        legacyMeObject.removeValue(forKey: "persistent")
        legacyMeObject.removeValue(forKey: "expires_at")
        legacyMeObject.removeValue(forKey: "absolute_expires_at")
        let legacyMe = try! JSONSerialization.data(withJSONObject: legacyMeObject)
        let bounded = BackendCredential(baseURL: person.base, token: person.token, expiresAt: .now.addingTimeInterval(30),
                                        userID: person.user, workspaceID: person.workspace)
        let runningStore = SessionMemoryStore(bounded); let running = fixture(runningStore)
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/auth/me" { fixture.respond(200, legacyMe) }
            else { person.serve(request, fixture) }
        }
        await running.restore(); install(person)
        await running.expireSessionIfNeeded(now: Date.now.addingTimeInterval(60), force: true)
        let runningSaved = await runningStore.value
        check(running.canAccessWorkspace && runningSaved?.expiresAt == nil && !running.isRestoring,
              "A running legacy session did not adopt its server-verified persistent lifetime")

        let raceStore = SessionMemoryStore(bounded); let race = fixture(raceStore)
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/auth/me" { fixture.respond(200, legacyMe) }
            else { person.serve(request, fixture) }
        }
        await race.restore(); install(person)
        let replaceGate = SessionFixtureGate(); await raceStore.pauseNextReplace(replaceGate)
        let upgrading = Task { await race.expireSessionIfNeeded(now: Date.now.addingTimeInterval(60), force: true) }
        await replaceGate.waitUntilEntered()
        check(race.isRestoring && !race.canAccessWorkspace, "Expired cached metadata was not gated while its upgrade waited")
        await race.logout()
        check(!race.isRestoring && !race.canAccessWorkspace, "Sign-out left an expired-session verification spinner active")
        let next = SessionPersona("next-persistent@example.test", persistent: true)
        install(next); await login(race, next)
        await replaceGate.release(); await upgrading.value
        let afterRace = await raceStore.value
        check(race.credential?.token == next.token && afterRace?.token == next.token && race.canAccessWorkspace,
              "A late lifetime update replaced the next sign-in or resurrected the old bearer")

        // Sign out from the locked reconnect screen: there is deliberately no
        // installed credential yet, but the saved bearer still needs revoking.
        let offlineStore = SessionMemoryStore(person.credential); let offline = fixture(offlineStore)
        let installation = UUID(); offline.pushInstallationID = installation
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await offline.restore(); await offline.logout()
        let offlineSaved = await offlineStore.value
        let pending = await offlineStore.revocations
        check(offlineSaved == nil && !offline.canAccessWorkspace && !offline.isWaitingForSavedSession,
              "Signing out from offline restoration retained a restorable session")
        check(pending.count == 1 && pending.first?.credential.token == person.token && pending.first?.pushInstallationID == installation,
              "Offline restoration sign-out lost the persistent bearer needed for remote revocation")
        let afterQuit = fixture(offlineStore); await afterQuit.restore()
        check(!afterQuit.canAccessWorkspace && afterQuit.credential == nil, "A queued sign-out token was restored after relaunch")
        install(next); await login(afterQuit, next)
        install(person); await afterQuit.retryPendingRevocations(force: true)
        let revocationsAfterRetry = await offlineStore.revocations
        let savedAfterRetry = await offlineStore.value
        check(revocationsAfterRetry.isEmpty && savedAfterRetry?.token == next.token && afterQuit.credential?.token == next.token,
              "Queued remote sign-out deleted or replaced a newer workspace session")

        let deleteStore = SessionMemoryStore(person.credential); let failedDelete = fixture(deleteStore); install(person)
        await failedDelete.restore(); await deleteStore.failNextDelete()
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await failedDelete.logout()
        let undeleted = await deleteStore.value
        let queuedAfterDeleteFailure = await deleteStore.revocations
        check(undeleted != nil && !failedDelete.canAccessWorkspace && queuedAfterDeleteFailure.count == 1,
              "Failed local deletion lost durable sign-out intent")
        let attemptedRestore = fixture(deleteStore); install(person); await attemptedRestore.restore()
        let afterBlockedRestore = await deleteStore.value
        check(!attemptedRestore.canAccessWorkspace && attemptedRestore.credential == nil && afterBlockedRestore == nil,
              "A failed Keychain deletion restored a token already queued for revocation")
        await attemptedRestore.retryPendingRevocations(force: true)
        let afterFinalRevocation = await deleteStore.revocations
        check(afterFinalRevocation.isEmpty, "Relaunch did not finish the saved revocation job")

        let unreadableStore = SessionMemoryStore(person.credential); let unreadable = fixture(unreadableStore)
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await unreadable.restore(); await unreadableStore.failNextLoad(); await unreadable.logout()
        check(unreadable.isWaitingForSignOut && !unreadable.canAccessWorkspace,
              "Keychain read failure forgot the user's sign-out intent")
        install(person); await unreadable.retrySavedSession(force: true)
        let afterUnreadableRetry = await unreadableStore.value
        check(!unreadable.canAccessWorkspace && !unreadable.isWaitingForSignOut && afterUnreadableRetry == nil,
              "Retrying a failed sign-out reopened the workspace instead of revoking the saved session")

        let unwritableStore = SessionMemoryStore(person.credential); let unwritable = fixture(unwritableStore); install(person)
        await unwritable.restore(); await unwritableStore.failNextRevocationSave()
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await unwritable.logout()
        let retainedForRevocation = await unwritableStore.value
        check(unwritable.isWaitingForSignOut && !unwritable.canAccessWorkspace && retainedForRevocation?.token == person.token,
              "Failed revocation-job write discarded the only bearer or lost sign-out intent")
        let sharedPreferences = preferencesBySession[ObjectIdentifier(unwritable)]!
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SessionFixtureProtocol.self]
        let relaunchedSignOut = BackendSession(storage: unwritableStore, configuration: configuration, preferences: sharedPreferences)
        install(person); await relaunchedSignOut.restore()
        let afterSignOutRelaunch = await unwritableStore.value
        check(!relaunchedSignOut.canAccessWorkspace && !relaunchedSignOut.isWaitingForSignOut && afterSignOutRelaunch == nil,
              "Relaunch restored a session whose sign-out was waiting for Keychain recovery")
    }

    static func accountData(_ accounts: [BackendAccount]) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(accounts)
    }

    static func signOutCutoffs() async {
        let person = SessionPersona("cutoff@example.test", persistent: true)
        let store = SessionMemoryStore(person.credential); let session = fixture(store); install(person)
        await session.restore()
        SessionFixtureProtocol.recorder = SessionRequestRecorder()
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await session.logout()
        let pending = await store.revocations
        check(pending.count == 1 && pending.first?.requestedAt != nil, "Explicit sign-out did not preserve its MCP revocation cutoff")
        await session.retryPendingRevocations(force: true)
        let bodies = SessionFixtureProtocol.recorder.values.filter { $0.path == "/v1/auth/logout" }.compactMap {
            (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]
        }
        check(bodies.count == 2 && bodies.allSatisfy { $0["revoke_mcp"] as? Bool == true }
              && bodies[0]["signed_out_at"] as? String != nil && bodies[0]["signed_out_at"] as? String == bodies[1]["signed_out_at"] as? String,
              "A delayed sign-out retry changed its cutoff and could revoke a newer MCP connection")

        var legacyObject = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(pending[0])) as! [String: Any]
        legacyObject.removeValue(forKey: "requestedAt")
        let legacy = try! JSONDecoder().decode(BackendPendingRevocation.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(legacy.requestedAt == nil, "Pre-cutoff revocation records no longer decode")
        let legacyStore = SessionMemoryStore(); try! await legacyStore.enqueueRevocation(legacy)
        let legacySession = fixture(legacyStore); install(person)
        SessionFixtureProtocol.recorder = SessionRequestRecorder()
        await legacySession.retryPendingRevocations(force: true)
        let legacyBody = SessionFixtureProtocol.recorder.values.first { $0.path == "/v1/auth/logout" }.flatMap {
            (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]
        }
        check(legacyBody?["revoke_mcp"] as? Bool == false && legacyBody?["signed_out_at"] == nil,
              "A legacy offline job without its original timestamp revoked current MCP connections")

        let readStore = SessionMemoryStore(person.credential); let unreadable = fixture(readStore)
        SessionFixtureProtocol.handler = { _, fixture in fixture.failOffline() }
        await unreadable.restore(); await readStore.failNextLoad(); await unreadable.logout()
        let preferences = preferencesBySession[ObjectIdentifier(unreadable)]!
        let originalDate = preferences.object(forKey: "postmerePendingSignOutDate.v1") as? Date
        check(originalDate != nil, "Sign-out intent lost its date when Keychain could not be read")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SessionFixtureProtocol.self]
        let relaunched = BackendSession(storage: readStore, configuration: config, preferences: preferences)
        await relaunched.restore()
        let queuedAfterRelaunch = await readStore.revocations
        check(queuedAfterRelaunch.first?.requestedAt == originalDate && !relaunched.canAccessWorkspace,
              "Keychain recovery after relaunch moved the sign-out cutoff forward")

        let cleanupStore = SessionMemoryStore(); let cleanup = fixture(cleanupStore)
        let wrong = SessionPersona("wrong-cutoff@example.test", persistent: true)
        SessionFixtureProtocol.recorder = SessionRequestRecorder()
        SessionFixtureProtocol.handler = { request, fixture in
            if request.url?.path == "/v1/auth/me" { fixture.respond(200, wrong.me) }
            else { person.serve(request, fixture) }
        }
        await login(cleanup, person)
        let cleanupBody = SessionFixtureProtocol.recorder.values.first { $0.path == "/v1/auth/logout" }.flatMap {
            (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]
        }
        check(!cleanup.canAccessWorkspace && cleanupBody?["revoke_mcp"] as? Bool == false,
              "Failed-login cleanup revoked MCP connections without a user sign-out")
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
        check(catalog(session).count == 32 && Set(catalog(session).map(\.localID)).count == 32, "Focus catalog capped or merged the account list")
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
        check(catalog(session).count == 31 && !catalog(session).contains(where: { $0.accountID == victim }), "Stale account-list response restored a disconnected Focus entry")

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
        check(catalog(session).map(\.accountID) == [new.account], "A previous scope's response replaced the Focus catalog")

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
