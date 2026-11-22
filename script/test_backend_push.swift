import Foundation

actor PushFixtureStorage: BackendCredentialStorage {
    var value: BackendCredential?
    private var revocations: [BackendPendingRevocation] = []
    init(_ value: BackendCredential? = nil) { self.value = value }
    func load() -> BackendCredential? { value }
    func save(_ credential: BackendCredential) { value = credential }
    func delete() { value = nil }
    func replace(_ credential: BackendCredential, matchingToken: String) -> Bool {
        guard let current = value, current.token == matchingToken, current.baseURL == credential.baseURL,
              current.userID == credential.userID, current.workspaceID == credential.workspaceID else { return false }
        value = credential
        return true
    }
    func pendingRevocations() -> [BackendPendingRevocation] { revocations }
    func enqueueRevocation(_ item: BackendPendingRevocation) {
        guard !revocations.contains(where: { $0.id == item.id }) else { return }
        revocations.append(item)
    }
    func removeRevocation(id: UUID) { revocations.removeAll { $0.id == id } }
}

nonisolated final class PushFixtureServer: @unchecked Sendable {
    let credential: BackendCredential
    let accountID: UUID
    private let sessionID = UUID()
    private let lock = NSLock()
    private var registrationValues: [[String: Any]] = []
    private var preferenceValues: [[String: Any]] = []
    private var activeAccountIDs: [String]
    private var enabled = true
    private var configured = true
    private var environment = "sandbox"
    private var nextStatusError: Int?
    private var failNextUpdate = false
    private var policyVersion: Int? = 1
    private var heldUpdate: (@Sendable (PushHeldRequest) -> Void)?

    init(credential: BackendCredential, accountID: UUID) {
        self.credential = credential
        self.accountID = accountID
        activeAccountIDs = [accountID.uuidString]
    }
    var registrations: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return registrationValues }
    var preferenceUpdates: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return preferenceValues }
    func setConfigured(_ value: Bool) { lock.lock(); defer { lock.unlock() }; configured = value }
    func failStatusOnce(_ code: Int = 503) { lock.lock(); defer { lock.unlock() }; nextStatusError = code }
    func failUpdateOnce() { lock.lock(); defer { lock.unlock() }; failNextUpdate = true }
    func setPolicyVersion(_ value: Int?) { lock.lock(); defer { lock.unlock() }; policyVersion = value }
    func holdNextUpdate(_ receive: @escaping @Sendable (PushHeldRequest) -> Void) { lock.lock(); defer { lock.unlock() }; heldUpdate = receive }
    func handle(_ request: URLRequest, _ fixture: RealtimeFixtureProtocol) {
        let path = request.url!.path
        if path != "/v1/auth/login", request.value(forHTTPHeaderField: "Authorization") != "Bearer \(credential.token)" {
            fixture.response(401)
            return
        }
        if path == "/v1/auth/login" {
            respond(fixture, ["token":credential.token,"session_id":sessionID.uuidString,
                "user_id":credential.userID.uuidString,"workspace_id":credential.workspaceID.uuidString,
                "role":"owner","persistent":true,"expires_at":NSNull(),"absolute_expires_at":NSNull()])
        } else if path == "/v1/auth/me" {
            respond(fixture, ["session_id":sessionID.uuidString,"user_id":credential.userID.uuidString,
                "workspace_id":credential.workspaceID.uuidString,"role":"owner","email":"fixture@example.test",
                "persistent":true,"expires_at":NSNull(),"absolute_expires_at":NSNull()])
        } else if path == "/v1/mail/accounts" {
            respond(fixture, [["id":accountID.uuidString,"provider":"gmail","email":"fixture@example.test","status":"connected"]])
        } else if path == "/v1/auth/logout" {
            fixture.response(204)
        } else if path.hasPrefix("/v1/push/devices/") {
            lock.lock()
            if request.httpMethod == "GET", let code = nextStatusError {
                nextStatusError = nil
                lock.unlock()
                fixture.response(code)
                return
            }
            if ["PUT", "PATCH"].contains(request.httpMethod ?? ""), let hold = heldUpdate {
                heldUpdate = nil
                lock.unlock()
                hold(PushHeldRequest(request: request, fixture: fixture))
                return
            }
            if ["PUT", "PATCH"].contains(request.httpMethod ?? ""), failNextUpdate {
                failNextUpdate = false
                lock.unlock()
                fixture.response(503)
                return
            }
            if request.httpMethod == "PUT" || request.httpMethod == "PATCH" {
                let body = (try? JSONSerialization.jsonObject(with: RealtimeFixtureProtocol.body(request))) as? [String: Any] ?? [:]
                if request.httpMethod == "PUT" {
                    registrationValues.append(body)
                    environment = body["environment"] as? String ?? ""
                } else { preferenceValues.append(body) }
                enabled = body["enabled"] as? Bool == true
                activeAccountIDs = (body["accounts"] as? [[String: Any]] ?? []).filter { $0["enabled"] as? Bool == true }.compactMap { $0["account_id"] as? String }
            } else if request.httpMethod == "DELETE" {
                enabled = false
                activeAccountIDs = []
            }
            var value: [String: Any] = ["configured":configured,"enabled":enabled,"active":configured,"environment":environment,
                "device_id":request.url!.lastPathComponent,"account_ids":enabled && configured ? activeAccountIDs : []]
            if let policyVersion { value["sender_policy_version"] = policyVersion }
            lock.unlock()
            if request.httpMethod == "DELETE" { fixture.response(204) }
            else { respond(fixture, value) }
        } else { fixture.response(404) }
    }
    private func respond(_ fixture: RealtimeFixtureProtocol, _ value: Any) {
        fixture.response(200, headers: ["Content-Type":"application/json"], chunks: [try! JSONSerialization.data(withJSONObject: value)])
    }
}

nonisolated struct PushHeldRequest: @unchecked Sendable {
    let request: URLRequest
    let fixture: RealtimeFixtureProtocol
}

@main
struct BackendPushFixtures {
    static func main() async throws {
        let suite = "postmere-push-fixtures-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); RemoteAccountRegistry.accounts = [] }
        let credential = BackendCredential(baseURL: "https://postmere.example.test", token: "fixture-only-token", expiresAt: nil, userID: UUID(), workspaceID: UUID())
        let server = PushFixtureServer(credential: credential, accountID: UUID())
        RealtimeFixtureProtocol.recorder = RealtimeFixtureRecorder()
        RealtimeFixtureProtocol.handler = { request, fixture in server.handle(request, fixture) }
        let storage = PushFixtureStorage()
        let session = BackendSession(storage: storage, configuration: RealtimeFixtureProtocol.configuration(), preferences: defaults)
        session.baseURL = credential.baseURL
        await session.login(email: "fixture@example.test", password: "fixture-only-password", workspaceID: credential.workspaceID.uuidString)
        try realtimeCheck(session.canAccessWorkspace && session.credential?.expiresAt == nil
                          && session.credential?.absoluteExpiresAt == nil, "Persistent fixture workspace did not sign in")
        let account = RemoteAccountRegistry.accounts[0]
        var profile = NotificationProfile(id: account.localID)
        profile.enabled = true
        profile.scheduleEnabled = true
        profile.startMinute = 22 * 60
        profile.endMinute = 6 * 60
        profile.weekdays = [2,3,4,5,6]
        profile.showPreview = false
        let preferences = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: true,
            senderScreeningEnabled: false, senderRules: [], timeZone: TimeZone(identifier: "Africa/Lagos")!)
        let service = MailPushService(preferences: defaults, environment: .sandbox)
        session.pushInstallationID = service.installationID
        session.onAccountCatalogChanged = { [weak session, weak service] in service?.reset(generation: session?.realtimeGeneration) }
        server.failStatusOnce()
        await service.synchronize(session: session, preferences: preferences)
        try realtimeCheck(!service.hasResolvedDeliveryOwnership && !service.allowsLocalIncoming(for: account.localID),
                          "Unknown startup delivery ownership must defer alerts rather than duplicate an earlier APNs alert")
        await service.synchronize(session: session, preferences: preferences, forceStatus: true)
        try realtimeCheck(service.remoteAccountIDs == [account.localID], "Startup did not recover remote ownership before any token callback")
        try realtimeCheck(server.registrations.isEmpty, "Locally missing token must not invent registration")
        try realtimeCheck(server.preferenceUpdates.count == 1 && server.preferenceUpdates[0]["token"] == nil,
                          "Existing registration preferences were not updated before an APNs callback")
        let enabledStatus = service.statusText
        service.registrationFailed()
        server.failStatusOnce(404)
        await service.synchronize(session: session, preferences: preferences, forceStatus: true)
        try realtimeCheck(service.remoteAccountIDs.isEmpty && service.allowsLocalIncoming(for: account.localID)
                          && service.statusText != enabledStatus && service.lastError != nil,
                          "Missing device must clear old delivery status and retain the pending Apple registration error")

        let token = Data([0,1,2,0xfd,0xfe,0xff,0x7f])
        service.registered(token: token)
        service.registered(token: token)
        await service.synchronize(session: session, preferences: preferences)
        try realtimeCheck(server.registrations.count == 2 && service.lastError == nil, "Every identical APNs registration callback must still upload and clear a previous registration error")
        let uploaded = server.registrations[0]
        try realtimeCheck(uploaded["token"] as? String == "000102fdfeff7f" && uploaded["environment"] as? String == "sandbox", "Opaque token conversion or signed environment changed")
        let uploadedAccount = (uploaded["accounts"] as! [[String: Any]])[0]
        try realtimeCheck(uploadedAccount["filter_criteria"] as? String == account.localID && uploadedAccount["time_zone"] as? String == "Africa/Lagos", "Focus identity or IANA timezone was lost")
        try realtimeCheck(uploadedAccount["show_subject"] as? Bool == false && uploadedAccount["start_minute"] as? Int == 1320 && uploadedAccount["end_minute"] as? Int == 360, "Preview or overnight schedule preferences changed")
        await service.synchronize(session: session, preferences: preferences)
        try realtimeCheck(server.registrations.count == 2, "Unchanged preferences unnecessarily repeated registration")
        try realtimeCheck(!defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("000102fdfeff7f") == true }, "APNs token was persisted as local truth")

        let denied = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: false, senderScreeningEnabled: false, senderRules: [])
        service.registered(token: token)
        await service.synchronize(session: session, preferences: denied)
        try realtimeCheck(server.registrations.count == 3 && server.registrations.last?["enabled"] as? Bool == false,
                          "Alert denial must disable alerts without suppressing APNs token registration")
        try realtimeCheck(service.remoteAccountIDs.isEmpty, "Disabled device still claimed local notification ownership")
        await service.synchronize(session: session, preferences: preferences)
        try realtimeCheck(server.registrations.count == 3 && service.remoteAccountIDs == [account.localID], "Re-enabling preferences did not restore remote delivery with a token-free update")

        let screened = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: true, senderScreeningEnabled: true, senderRules: [])
        try realtimeCheck(screened.accounts[0].enabled && screened.accounts[0].senderPolicy?.permits(senderEmail: "unknown@example.test") == false,
                          "Sender screening disabled the whole account or allowed an unknown sender")
        let blocked = SenderRule(email: "blocked@example.test", account: account.localID, route: .blocked)
        let routed = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: true, senderScreeningEnabled: false, senderRules: [blocked])
        try realtimeCheck(routed.accounts[0].enabled && routed.accounts[0].senderPolicy?.permits(senderEmail: blocked.email) == false,
                          "Blocked sender disabled the whole account or escaped its mirrored policy")
        let anotherRule = SenderRule(email: "blocked@example.test", account: "different-workspace", route: .blocked)
        let unaffected = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: true, senderScreeningEnabled: false, senderRules: [anotherRule])
        try realtimeCheck(unaffected.accounts[0].enabled && unaffected.accounts[0].senderPolicy?.rules.isEmpty == true, "A different workspace's rule affected this account")
        await service.synchronize(session: session, preferences: screened)
        try realtimeCheck(service.remoteAccountIDs == [account.localID] && !service.allowsLocalIncoming(for: account.localID),
                          "Capable server lost screened-account delivery ownership and enabled duplicate local alerts")
        let policyUpload = (server.preferenceUpdates.last?["accounts"] as? [[String: Any]])?.first?["sender_policy"] as? [String: Any]
        try realtimeCheck(policyUpload?["version"] as? Int == 1 && policyUpload?["screen_unknown_senders"] as? Bool == true,
                          "Screening policy did not reach the authenticated preference endpoint")
        try await policyFixtures(service: service, session: session, server: server, account: account, profile: profile)

        let unsigned = MailPushService(preferences: defaults, environment: nil)
        let beforeUnsigned = RealtimeFixtureProtocol.recorder.requests.count
        unsigned.registered(token: token)
        unsigned.registrationFailed()
        await unsigned.synchronize(session: session, preferences: preferences)
        try realtimeCheck(RealtimeFixtureProtocol.recorder.requests.count == beforeUnsigned && unsigned.remoteAccountIDs.isEmpty &&
                          unsigned.lastError == nil && unsigned.statusText.contains("while Postmere is open"),
                          "Unsigned build chose a guessed APNs environment or claimed remote delivery")
        server.setConfigured(false)
        await service.synchronize(session: session, preferences: preferences, forceStatus: true)
        try realtimeCheck(service.remoteAccountIDs.isEmpty, "Unconfigured server disabled local notification fallback")
        server.setConfigured(true)
        await service.synchronize(session: session, preferences: preferences, forceStatus: true)
        try realtimeCheck(service.remoteAccountIDs == [account.localID], "Configured server did not recover remote ownership")

        let beyondOneDay = Date.now.addingTimeInterval(25 * 60 * 60)
        let persistentGeneration = session.realtimeGeneration
        await session.expireSessionIfNeeded(now: beyondOneDay, force: true)
        let persisted = await storage.load()
        try realtimeCheck(session.canAccessWorkspace && session.credential?.isValid(at: beyondOneDay) == true
                          && session.realtimeGeneration == persistentGeneration && persisted?.expiresAt == nil,
                          "Persistent sign-in was expired or reset by a clock check more than 24 hours later")
        try realtimeCheck(service.hasResolvedDeliveryOwnership && service.remoteAccountIDs == [account.localID]
                          && !service.allowsLocalIncoming(for: account.localID),
                          "Persistent workspace age lost APNs ownership or enabled duplicate local alerts")
        let registrationsBeforeNextDay = server.registrations.count
        let requestsBeforeNextDay = RealtimeFixtureProtocol.recorder.requests.count
        service.registered(token: token)
        await service.synchronize(session: session, preferences: preferences, forceStatus: true)
        let nextDayRequests = Array(RealtimeFixtureProtocol.recorder.requests.dropFirst(requestsBeforeNextDay))
        try realtimeCheck(server.registrations.count == registrationsBeforeNextDay + 1
                          && service.remoteAccountIDs == [account.localID]
                          && nextDayRequests.count == 2 && nextDayRequests[0].httpMethod == "GET"
                          && nextDayRequests[1].httpMethod == "PUT"
                          && nextDayRequests.allSatisfy { $0.url?.path == "/v1/push/devices/\(service.installationID.uuidString)"
                              && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential.token)" },
                          "Push ownership lookup and fresh token registration did not continue under the persistent session")

        try destinationFixtures(credential: credential, account: account)
        var many: [RemoteAccountIdentity] = []
        for index in 0..<300 {
            many.append(RemoteAccountIdentity(localID: "remote:fixture:\(index)", accountID: UUID(), scope: "fixture", email: "\(index)@example.test", displayName: "Fixture", provider: index.isMultiple(of: 2) ? "gmail" : "microsoft"))
        }
        let manyPreferences = MailPushPreferences.workspace(accounts: many, profiles: [], authorized: true, senderScreeningEnabled: false, senderRules: [])
        try realtimeCheck(manyPreferences.accounts.count == 300 && Set(manyPreferences.accounts.map(\.accountId)).count == 300, "Push preferences truncated or conflated a large account catalog")

        let oldGeneration = session.realtimeGeneration
        session.clearSession()
        try realtimeCheck(service.remoteAccountIDs.isEmpty && service.statusText.contains("Sign in") && service.lastError == nil,
                          "Session clear retained stale notification ownership, status or errors")
        await storage.save(credential)
        await session.restore()
        try realtimeCheck(session.realtimeGeneration != oldGeneration, "Same user/workspace restore reused the old login generation")
        // The workspace scene reconciles its push generation when verified access resumes.
        service.reset(generation: session.realtimeGeneration)
        try realtimeCheck(service.statusText.contains("Checking"), "A new login showed stale background notification status before its own lookup")
        let registrationsBeforeRestore = server.registrations.count
        await service.synchronize(session: session, preferences: preferences)
        try realtimeCheck(server.registrations.count == registrationsBeforeRestore,
                          "New login must await an actual APNs callback instead of uploading an old cached token")
        let beforeLogout = RealtimeFixtureProtocol.recorder.requests.count
        await session.logout()
        let logoutRequests = Array(RealtimeFixtureProtocol.recorder.requests.dropFirst(beforeLogout))
        try realtimeCheck(logoutRequests.count == 2 && logoutRequests[0].httpMethod == "DELETE"
                          && logoutRequests[0].url?.path == "/v1/push/devices/\(service.installationID.uuidString)"
                          && logoutRequests[1].url?.path == "/v1/auth/logout", "Logout did not remove the device before revoking its old session")
        try realtimeCheck(!session.canAccessWorkspace && service.remoteAccountIDs.isEmpty, "Logout did not immediately clear notification ownership")
        let pendingRevocations = await storage.pendingRevocations()
        try realtimeCheck(pendingRevocations.isEmpty, "Confirmed logout retained a pending revocation")
        print("PASS: every APNs token callback, signed environment, memory-only tokens, alert-permission separation and preference mirroring")
        print("PASS: initial remote ownership, local fallback, screened/blocked account protection, 300 identities and scoped deep links")
        print("PASS: persistent workspace access beyond 24 hours retains APNs ownership and authenticated registration")
        print("PASS: ordered scoped sender policies, token-free edits, old-server fallback, failed-update ownership and concurrent policy changes")
        print("PASS: login generation reset and authenticated device deletion before logout; no APNs, Keychain or real server contacted")
    }

    static func policyFixtures(service: MailPushService, session: BackendSession, server: PushFixtureServer,
                               account: RemoteAccountIdentity, profile: NotificationProfile) async throws {
        let rules = [
            SenderRule(email: "APPROVED@example.test", account: nil, route: .inbox),
            SenderRule(email: "approved@example.test", account: account.localID, route: .blocked),
            SenderRule(email: "reply@example.test", account: account.localID, route: .needsReply, providerAccountEmail: account.email.uppercased()),
            SenderRule(email: "archive@example.test", account: account.localID, route: .archive),
            SenderRule(email: "blocked@example.test", account: account.localID, route: .blocked),
            SenderRule(email: "other@example.test", account: "another-workspace", route: .inbox),
            SenderRule(email: "provider@example.test", account: account.localID, route: .inbox, providerAccountEmail: "another-provider@example.test")
        ]
        let screened = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: true,
            senderScreeningEnabled: true, senderRules: rules)
        let policy = screened.accounts[0].senderPolicy!
        try realtimeCheck(policy.rules.map(\.email) == ["approved@example.test", "approved@example.test", "reply@example.test", "archive@example.test", "blocked@example.test"],
                          "Mirrored rules lost first-match order, normalization or account/provider isolation")
        try realtimeCheck(policy.permits(senderEmail: "APPROVED@EXAMPLE.TEST") && policy.permits(senderEmail: "reply@example.test"),
                          "Accepted inbox/needs-reply senders cannot receive background notifications")
        for sender in ["archive@example.test", "blocked@example.test", "unknown@example.test", "other@example.test", "provider@example.test"] {
            try realtimeCheck(!policy.permits(senderEmail: sender), "Screened or routed sender escaped background policy: \(sender)")
        }
        let organisation = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: true, senderScreeningEnabled: true, senderRules: [
            SenderRule.domain("LinkedIn.com", account: account.localID, route: .inbox, providerAccountEmail: nil),
            SenderRule(email: "ads@linkedin.com", account: account.localID, route: .blocked)]).accounts[0].senderPolicy!
        try realtimeCheck(organisation.rules.first?.email == "*@linkedin.com"
                          && organisation.permits(senderEmail: "jobs@E.linkedin.com") && !organisation.permits(senderEmail: "ads@linkedin.com")
                          && !organisation.permits(senderEmail: "x@linkedin.com.evil.test"),
                          "Domain approvals must cover subdomains, yield to address rules and reject lookalikes")
        let reversed = MailPushSenderPolicy(screenUnknownSenders: false, rules: Array(policy.rules.reversed()))
        try realtimeCheck(!reversed.permits(senderEmail: "approved@example.test") && reversed.permits(senderEmail: "unknown@example.test"),
                          "Rule precedence or unscreened default differs from native incoming-mail rules")
        await service.synchronize(session: session, preferences: screened)
        try realtimeCheck(service.remoteAccountIDs == [account.localID], "Approved-sender policy lost account notification ownership")

        // An old server retains its active ownership until it confirms the
        // disabling registration; a failed update must not enable local alerts.
        server.setPolicyVersion(nil); server.failUpdateOnce()
        await service.synchronize(session: session, preferences: screened, forceStatus: true)
        try realtimeCheck(service.remoteAccountIDs == [account.localID] && !service.allowsLocalIncoming(for: account.localID) && service.lastError != nil,
                          "A rejected old-server disable enabled duplicate local incoming alerts")
        await service.synchronize(session: session, preferences: screened, forceStatus: true)
        let legacyAccount = (server.registrations.last?["accounts"] as? [[String: Any]])?.first
        try realtimeCheck(service.remoteAccountIDs.isEmpty && service.allowsLocalIncoming(for: account.localID)
                          && legacyAccount?["enabled"] as? Bool == false && legacyAccount?["sender_policy"] == nil,
                          "An older server received unsupported policy fields or bypassed native filtering")
        server.setPolicyVersion(1)
        await service.synchronize(session: session, preferences: screened, forceStatus: true)
        try realtimeCheck(service.remoteAccountIDs == [account.localID], "Upgraded server did not regain screened account ownership")

        let first = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: true,
            senderScreeningEnabled: false, senderRules: [])
        let latest = MailPushPreferences.workspace(accounts: [account], profiles: [profile], authorized: true,
            senderScreeningEnabled: true, senderRules: [SenderRule(email: "newly-approved@example.test", account: account.localID, route: .inbox)])
        let (updates, continuation) = AsyncStream.makeStream(of: PushHeldRequest.self, bufferingPolicy: .bufferingNewest(1))
        server.holdNextUpdate { continuation.yield($0) }
        let firstSync = Task { await service.synchronize(session: session, preferences: first) }
        var iterator = updates.makeAsyncIterator()
        let held = await iterator.next()!
        var secondStarted = false
        let nextSync = Task { secondStarted = true; await service.synchronize(session: session, preferences: latest) }
        try await eventually("Concurrent policy edit did not start") { secondStarted }
        server.handle(held.request, held.fixture)
        continuation.finish()
        await firstSync.value; await nextSync.value
        let finalPolicy = (server.preferenceUpdates.last?["accounts"] as? [[String: Any]])?.first?["sender_policy"] as? [String: Any]
        let finalRules = finalPolicy?["rules"] as? [[String: Any]]
        try realtimeCheck(finalPolicy?["screen_unknown_senders"] as? Bool == true
                          && finalRules?.first?["email"] as? String == "newly-approved@example.test"
                          && service.lastError == nil && service.remoteAccountIDs == [account.localID],
                          "A policy edit during upload was dropped or overwritten by the earlier snapshot")
    }

    static func destinationFixtures(credential: BackendCredential, account: RemoteAccountIdentity) throws {
        let message = UUID()
        let info: [AnyHashable: Any] = ["postmere_push":1,"server_origin":"https://POSTMERE.EXAMPLE.TEST:443/",
            "workspace_id":credential.workspaceID.uuidString,"user_id":credential.userID.uuidString,
            "account_id":account.accountID.uuidString,"message_id":message.uuidString,"filter_criteria":account.localID]
        let destination = MailPushDestination(userInfo: info)!
        try realtimeCheck(destination.matches(credential, account: account) && destination.messageID == message, "Valid canonical-origin notification did not resolve")
        for (key, value) in [("server_origin","https://attacker.example.test"),("workspace_id",UUID().uuidString),
                             ("user_id",UUID().uuidString),("account_id",UUID().uuidString),("filter_criteria","another-account")] {
            var altered = info; altered[key] = value
            try realtimeCheck(MailPushDestination(userInfo: altered)?.matches(credential, account: account) != true,
                              "Notification crossed its \(key) boundary")
        }
        var insecure = info; insecure["server_origin"] = "http://postmere.example.test"
        try realtimeCheck(MailPushDestination(userInfo: insecure) == nil, "Insecure notification origin was accepted")
        var unknown = info; unknown["postmere_push"] = 2
        try realtimeCheck(MailPushDestination(userInfo: unknown) == nil, "Unknown push payload version was accepted")
    }
}
