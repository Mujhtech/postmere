import Foundation

@MainActor
private final class SenderProfileGate {
    private var continuation: CheckedContinuation<BackendSenderProfileResponse, Never>?
    private(set) var waiting = false
    func wait() async -> BackendSenderProfileResponse {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting = true
        }
    }
    func finish(_ response: BackendSenderProfileResponse) {
        guard let continuation else { preconditionFailure("Missing pending profile request") }
        self.continuation = nil
        waiting = false
        continuation.resume(returning: response)
    }
}

@main
private struct SenderProfileChecks {
    @MainActor static func main() async throws {
        try modelFixtures()
        try eligibilityFixtures()
        try await requestFixtures()
        try await revalidationFixtures()
        try await cancellationFixtures()
        try await invalidResponseFixtures()
        print("PASS: sender profiles use isolated in-memory fixtures; no enrichment provider or real mailbox was contacted")
    }

    @MainActor private static func response(email: String = "ada@example.test", status: String = "matched", name: String = "Ada Lovelace", includesProfile: Bool = true, cited: Bool = true, includesUnlistedLink: Bool = false, usesEmployerLinkCitation: Bool = false) throws -> BackendSenderProfileResponse {
        var value: [String: Any] = ["email": email, "status": status, "checked_at": "2026-11-20T12:34:56.123456Z"]
        if includesProfile {
            value["profile"] = [
                "name": name, "job_title": "Research engineer", "company": "Analytical Engines",
                "location": "London, UK", "bio": "Public professional biography.",
                "links": [["label": "LinkedIn", "url": "https://www.linkedin.com/in/ada-fixture"],
                          ["label": "Website", "url": "https://ada.example.com"]],
                "source": ["name": "Public profile", "url": "https://profiles.example.com/ada"],
                "sources": [["name": "Public profile", "url": "https://profiles.example.com/ada"],
                            ["name": "LinkedIn", "url": "https://www.linkedin.com/in/ada-fixture"],
                            ["name": "Website", "url": "https://ada.example.com"]],
                "citations": cited ? ["name", "job_title", "company", "location", "bio"].map {
                    ["field": $0, "source_urls": ["https://profiles.example.com/ada"]] as [String: Any]
                } + [["field": "links", "source_urls": usesEmployerLinkCitation
                        ? ["https://engines.example.com/team/ada"]
                        : ["https://www.linkedin.com/in/ada-fixture", "https://ada.example.com"]]] : []
            ]
            if includesUnlistedLink {
                var profile = value["profile"] as! [String: Any]
                var links = profile["links"] as! [[String: String]]
                links.append(["label": "Injected promotion", "url": "https://promoted.example.com"])
                profile["links"] = links
                value["profile"] = profile
            }
            if usesEmployerLinkCitation {
                var profile = value["profile"] as! [String: Any]
                var sources = profile["sources"] as! [[String: String]]
                sources.append(["name": "Employer team page", "url": "https://engines.example.com/team/ada"])
                profile["sources"] = sources
                value["profile"] = profile
            }
        }
        return try BackendHTTPClient.decoder().decode(BackendSenderProfileResponse.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor private static func target(email: String = "ada@example.test", accountID: UUID = UUID(), scope: String = "origin-a:workspace-a:user-a", session: UUID = UUID(), messageID: UUID = UUID()) -> SenderProfileTarget {
        SenderProfileTarget(messageID: messageID, accountID: accountID, scope: scope, sessionGeneration: session, email: email)
    }

    @MainActor private static func loaded(_ service: MailSenderProfile) throws -> BackendSenderProfileResponse {
        guard case let .loaded(response) = service.phase else {
            throw RealtimeFixtureFailure(message: "Expected a loaded sender profile")
        }
        return response
    }

    @MainActor private static func modelFixtures() throws {
        let matched = try response()
        try realtimeCheck(matched.email == "ada@example.test" && matched.status.rawValue == "matched", "Sender address and match status did not decode")
        try realtimeCheck(matched.profile?.name == "Ada Lovelace" && matched.profile?.jobTitle == "Research engineer" && matched.profile?.company == "Analytical Engines", "Professional fields did not decode with the transport's snake_case contract")
        try realtimeCheck(matched.profile?.location == "London, UK" && matched.profile?.links.count == 2 && matched.checkedAt != nil, "Profile links, location, or checked date were lost")
        try realtimeCheck(matched.profile?.publicSources.count == 3 && matched.profile?.sources(for: "job_title").count == 1,
                          "Public source attribution and field citations must stay attached to researched details")
        let employerCited = try response(usesEmployerLinkCitation: true)
        try realtimeCheck(employerCited.profile?.sources(for: "links").map(\.url) == ["https://engines.example.com/team/ada"] &&
                          employerCited.profile?.publicLinks.contains(where: { $0.url == "https://www.linkedin.com/in/ada-fixture" }) == true,
                          "A LinkedIn URL independently listed in public sources must remain visible when the employer page supports the links field")
        let injected = try response(includesUnlistedLink: true, usesEmployerLinkCitation: true)
        try realtimeCheck(injected.profile?.publicLinks.count == 2 && injected.profile?.publicLinks.contains(where: { $0.url == "https://promoted.example.com" }) == false,
                          "A links-field citation must not make an invented contact URL absent from public sources clickable")
        for unsafe in ["javascript:alert(1)", "data:text/html,profile", "http://profiles.example.com/ada",
                       "https://secret:password@profiles.example.com/ada", "https://localhost/profile",
                       "https://127.0.0.1/profile", "https://[::1]/profile", "https://private.local/profile",
                       "https://profiles.example.com:8443/ada"] {
            try realtimeCheck(BackendSenderProfile.publicURL(unsafe) == nil, "Unsafe researched link must not become clickable: \(unsafe)")
        }
        for status in ["not_found", "unconfigured", "disabled"] {
            let absent = try response(status: status, includesProfile: false)
            try realtimeCheck(absent.status.rawValue == status && absent.profile == nil, "A non-match state must decode without a profile")
        }
        for malformed in [#"{"status":"matched"}"#, #"{"email":"ada@example.test","status":"invented"}"#,
                          #"{"email":"ada@example.test","status":"matched","profile":{"links":"invalid"}}"#] {
            do {
                _ = try BackendHTTPClient.decoder().decode(BackendSenderProfileResponse.self, from: Data(malformed.utf8))
                throw RealtimeFixtureFailure(message: "Malformed profile contract was accepted")
            } catch is DecodingError { }
        }
        print("PASS: matched, absent, disabled and unconfigured profiles; public fields and malformed response contracts")
    }

    @MainActor private static func eligibilityFixtures() throws {
        let previousAccounts = RemoteAccountRegistry.accounts
        defer { RemoteAccountRegistry.accounts = previousAccounts }
        let account = RemoteAccountIdentity(localID: "remote:profile-fixture:account", accountID: UUID(), scope: "origin-a:workspace-a:user-a", email: "me@example.test", displayName: "Me", provider: "gmail")
        RemoteAccountRegistry.accounts = [account]
        let session = UUID()
        var incoming = MailMessage(sender: "Ada", senderEmail: " ADA@Example.Test ", initials: "A", subject: "Private subject marker", preview: "Private preview marker", paragraphs: ["Secret message contents must never reach enrichment"], timeLabel: "12:00", account: account.localID)
        incoming.backendMessageID = UUID()
        let eligible = SenderProfileTarget.make(message: incoming, scope: account.scope, sessionGeneration: session)
        try realtimeCheck(eligible?.messageID == incoming.backendMessageID && eligible?.accountID == account.accountID && eligible?.email == "ada@example.test", "An incoming backend sender must be eligible and normalized")
        try realtimeCheck(SenderProfileTarget.make(message: incoming, scope: "other-origin:workspace-a:user-a", sessionGeneration: session) == nil, "A different backend scope must not enrich the sender")
        try realtimeCheck(SenderProfileTarget.make(message: incoming, scope: account.scope, sessionGeneration: nil) == nil, "A disconnected session must not enrich a sender")
        var outgoing = incoming; outgoing.isOutgoing = true
        var draft = incoming; draft.mailbox = .drafts
        var queued = incoming; queued.mailbox = .outbox
        var local = incoming; local.backendMessageID = nil
        var deleted = incoming; deleted.providerDeletedAt = .now
        var malformed = incoming; malformed.senderEmail = "ada@example.test,other@example.test"
        for message in [outgoing, draft, queued, local, deleted, malformed] {
            try realtimeCheck(SenderProfileTarget.make(message: message, scope: account.scope, sessionGeneration: session) == nil, "Unsupported or ambiguous sender should not produce an enrichment target")
        }
        var reconnect = account; reconnect.status = "reconnect_required"
        RemoteAccountRegistry.accounts = [reconnect]
        try realtimeCheck(SenderProfileTarget.make(message: incoming, scope: account.scope, sessionGeneration: session) == nil, "An account needing reconnection must not enrich senders")
        RemoteAccountRegistry.accounts = []
        try realtimeCheck(SenderProfileTarget.make(message: incoming, scope: account.scope, sessionGeneration: session) == nil, "Removed account must not enrich cached messages")
        print("PASS: incoming-only eligibility, normalized addresses, account/session scope, removed accounts and unsupported messages")
    }

    @MainActor private static func requestFixtures() async throws {
        let recorder = RealtimeFixtureRecorder()
        RealtimeFixtureProtocol.recorder = recorder
        let payload = Data(#"{"email":"ada@example.test","status":"not_found","checked_at":"2026-11-20T12:34:56Z"}"#.utf8)
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(200, headers: ["Content-Type": "application/json"], chunks: [payload]) }
        let client = try BackendHTTPClient(baseURL: "https://postmere.example.test", configuration: RealtimeFixtureProtocol.configuration())
        let id = UUID()
        let _: BackendSenderProfileResponse = try await client.request(SenderProfileRequest.method, SenderProfileRequest.path(messageID: id), token: "profile-fixture-token", body: SenderProfileRequest(refresh: true))
        let request = recorder.requests[0]
        let body = try JSONSerialization.jsonObject(with: RealtimeFixtureProtocol.body(request)) as! [String: Any]
        try realtimeCheck(recorder.requests.count == 1 && request.httpMethod == "POST" && request.url?.path == "/v1/mail/messages/\(id.uuidString)/sender-profile", "Profile lookup path must be scoped to the selected backend message")
        try realtimeCheck(body.count == 1 && body["refresh"] as? Bool == true && request.url?.query == nil, "Only the refresh flag may be sent; no address, subject, body, or recipient data")
        try realtimeCheck(request.value(forHTTPHeaderField: "Authorization") == "Bearer profile-fixture-token" && request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "X-Ambient") == nil, "Enrichment request leaked ambient credentials")
        print("PASS: intercepted sender-profile POST sends only message ID and refresh, without email contents or ambient headers")
    }

    @MainActor private static func revalidationFixtures() async throws {
        let service = MailSenderProfile()
        let first = target()
        var count = 0
        let fetch: @MainActor (UUID, SenderProfileRequest) async throws -> BackendSenderProfileResponse = { _, _ in
            count += 1
            return try response()
        }
        await service.load(target: first, fetch: fetch)
        try realtimeCheck(try loaded(service).profile?.name == "Ada Lovelace" && count == 1, "First lookup must load a public profile")
        let sameSender = target(accountID: first.accountID, scope: first.scope, session: first.sessionGeneration)
        await service.load(target: sameSender, fetch: fetch)
        try realtimeCheck(count == 2, "Reselecting the same sender must revalidate with the server so opt-out and account revocation take effect")
        await service.load(target: sameSender, refresh: true) { _, request in
            try realtimeCheck(request.refresh, "Refresh flag was not passed to the transport")
            count += 1
            return try response(name: "Updated public name")
        }
        try realtimeCheck(count == 3 && (try loaded(service)).profile?.name == "Updated public name", "Explicit refresh must reach the server and replace the previous public profile")
        let otherAccount = target(scope: first.scope, session: first.sessionGeneration)
        await service.load(target: otherAccount, fetch: fetch)
        try realtimeCheck(count == 4, "The same sender in a second account must be revalidated in that account")
        let otherScope = target(accountID: first.accountID, scope: "origin-b:workspace-b:user-b", session: first.sessionGeneration)
        await service.load(target: otherScope, fetch: fetch)
        try realtimeCheck(count == 5, "A different server/workspace/user must never reuse a previous profile")
        let otherSession = target(accountID: first.accountID, scope: otherScope.scope)
        await service.load(target: otherSession, fetch: fetch)
        try realtimeCheck(count == 6, "New authenticated session must revalidate earlier profile data")
        service.cancel()
        await service.load(target: otherSession, fetch: fetch)
        try realtimeCheck(count == 7, "Resuming after cancellation must fetch a currently authorized result")

        for status in ["not_found", "unconfigured", "disabled"] {
            let state = MailSenderProfile()
            let request = target()
            var lookups = 0
            let missing: @MainActor (UUID, SenderProfileRequest) async throws -> BackendSenderProfileResponse = { _, _ in
                lookups += 1
                return try response(status: status, includesProfile: false)
            }
            await state.load(target: request, fetch: missing)
            await state.load(target: request, fetch: missing)
            try realtimeCheck(try loaded(state).status.rawValue == status, "State-specific profile result was lost")
            try realtimeCheck(lookups == 2, "Every selection must revalidate even a previous no-match or configuration state")
        }
        print("PASS: every selection revalidates server/account access, refresh propagation, session cleanup and no-match/configuration-state retry")
    }

    @MainActor private static func cancellationFixtures() async throws {
        let service = MailSenderProfile()
        let first = target()
        var viewIsCurrent = true
        var fetches = 0
        await service.load(target: first, isCurrent: {
            // Opening the panel succeeds, then selection changes before the lookup starts.
            defer { viewIsCurrent = false }
            return viewIsCurrent
        }) { _, _ in
            fetches += 1
            return try response()
        }
        try realtimeCheck(fetches == 0, "A dismissed sender panel dispatched a profile lookup")
        guard case .idle = service.phase else { throw RealtimeFixtureFailure(message: "A sender panel invalidated before dispatch stayed in the loading state") }

        let later = target(email: "grace@example.test", accountID: first.accountID, scope: first.scope, session: first.sessionGeneration)
        let gate = SenderProfileGate()
        var oldRequestCancelled = false
        let pending = Task {
            await service.load(target: first) { _, _ in
                let result = await gate.wait()
                oldRequestCancelled = Task.isCancelled
                return result
            }
        }
        try await eventually("Old sender lookup never started") { gate.waiting }
        await service.load(target: later) { _, _ in try response(email: later.email, name: "Grace Hopper") }
        gate.finish(try response())
        await pending.value
        try realtimeCheck(oldRequestCancelled && (try loaded(service)).email == later.email && service.target == later, "A late response from a previously selected sender replaced the current panel")

        let cancelledGate = SenderProfileGate()
        let cancelled = Task { await service.load(target: first) { _, _ in await cancelledGate.wait() } }
        try await eventually("Cancellable profile lookup never started") { cancelledGate.waiting }
        service.cancel()
        cancelledGate.finish(try response())
        await cancelled.value
        guard case .idle = service.phase else { throw RealtimeFixtureFailure(message: "Cancelled request repopulated the profile panel") }
        try realtimeCheck(service.target == nil, "Cancellation did not clear the selected sender")

        let callerGate = SenderProfileGate()
        var transportCancelled = false
        let cancelledCaller = Task {
            await service.load(target: first) { _, _ in
                let response = await callerGate.wait()
                transportCancelled = Task.isCancelled
                return response
            }
        }
        try await eventually("Caller-owned lookup never started") { callerGate.waiting }
        cancelledCaller.cancel()
        callerGate.finish(try response())
        await cancelledCaller.value
        try realtimeCheck(transportCancelled, "Cancelling the view task must cancel its provider lookup task")
        guard case .idle = service.phase else { throw RealtimeFixtureFailure(message: "A cancelled view task must stop the loading state even if its transport returns successfully") }

        let sessionGate = SenderProfileGate()
        var stillCurrent = true
        let staleSession = Task { await service.load(target: first, isCurrent: { stillCurrent }) { _, _ in await sessionGate.wait() } }
        try await eventually("Session-scoped profile lookup never started") { sessionGate.waiting }
        stillCurrent = false
        sessionGate.finish(try response())
        await staleSession.value
        if case .loaded = service.phase { throw RealtimeFixtureFailure(message: "A profile response from an invalidated session became visible") }
        var fetchedAgain = false
        await service.load(target: first) { _, _ in fetchedAgain = true; return try response(name: "Fresh authorized response") }
        try realtimeCheck(fetchedAgain && (try loaded(service)).profile?.name == "Fresh authorized response", "Stale session response prevented a fresh authorized lookup")
        print("PASS: pre-dispatch invalidation, sender-switch cancellation, late-result fences, explicit dismissal and invalidated-session result isolation")
    }

    @MainActor private static func invalidResponseFixtures() async throws {
        let service = MailSenderProfile()
        let request = target()
        for invalid in [try response(email: "different@example.test"), try response(includesProfile: false), try response(cited: false)] {
            await service.load(target: request, refresh: true) { _, _ in invalid }
            guard case .failed = service.phase else { throw RealtimeFixtureFailure(message: "A mismatched, incomplete, or entirely uncited profile must not be displayed") }
        }
        var recovered = false
        await service.load(target: request) { _, _ in recovered = true; return try response() }
        try realtimeCheck(recovered && (try loaded(service)).email == request.email, "Invalid response prevented a clean retry")
        await service.load(target: request, refresh: true) { _, _ in throw URLError(.notConnectedToInternet) }
        guard case .failed = service.phase else { throw RealtimeFixtureFailure(message: "Network failure must leave a retryable profile error") }
        print("PASS: response-address binding, uncited/incomplete matched results, uncached failures and retryable network errors")
    }
}
