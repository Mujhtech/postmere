import Foundation

nonisolated final class FixtureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var lastRequest: URLRequest?
    func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        counts[path, default: 0] += 1
        lastRequest = request
        return counts[path]!
    }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
}

nonisolated final class GmailFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

actor MemoryGmailCredentials: GmailCredentialStorage {
    var value: GmailCredentials?
    init(_ value: GmailCredentials?) { self.value = value }
    func load() -> GmailCredentials? { value }
    func save(_ credentials: GmailCredentials) { value = credentials }
    func delete() { value = nil }
}

@main
struct PostmereGmailFixtures {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GmailFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let credential = GmailCredentials(clientID: "fixture.apps.googleusercontent.com", accessToken: "fixture-access",
            refreshToken: "fixture-refresh", expiresAt: .now.addingTimeInterval(3600), email: "me@example.com")
        let storage = MemoryGmailCredentials(credential)
        let api = GmailAPIClient(storage: storage, session: session)
        let plain = "Hello café\n\nHere is your receipt."
        let html = "<html><head><style>bad style</style></head><body><p>Hello caf&eacute;</p><img src='https://example.com/tracker'><script>bad()</script><p>Receipt &amp; notes &#128522;</p></body></html>"
        let wireObject: [String: Any] = ["id": "abc123", "threadId": "thread123", "labelIds": ["INBOX", "UNREAD", "STARRED"],
            "snippet": "Hello &amp; receipt", "internalDate": "1700000000000", "payload": ["partId": "", "mimeType": "multipart/mixed", "headers": [
                ["name":"From", "value":"=?UTF-8?B?Sm9zw6k=?= <jose@example.com>"], ["name":"To", "value":"Me <me@example.com>"],
                ["name":"Subject", "value":"=?UTF-8?Q?Receipt_=E2=9C=93?="], ["name":"Message-ID", "value":"<receipt@example.com>"],
                ["name":"References", "value":"<prior@example.com>"]], "parts": [
                    ["partId":"0", "mimeType":"multipart/alternative", "parts": [
                        ["partId":"0.0", "mimeType":"text/plain", "body":["size":plain.utf8.count,"data":GmailEncoding.base64URL(Data(plain.utf8))]],
                        ["partId":"0.1", "mimeType":"text/html", "body":["size":html.utf8.count,"data":GmailEncoding.base64URL(Data(html.utf8))]]]],
                    ["partId":"1", "filename":"receipt.pdf", "mimeType":"application/pdf", "body":["size":4,"attachmentId":"attachment123"]]
                ]]]
        let wireData = try JSONSerialization.data(withJSONObject: wireObject)
        let wire = try JSONDecoder().decode(GmailWireMessage.self, from: wireData)
        let mapped = GmailMessageMapper.message(wire, accountEmail: "me@example.com")
        precondition(mapped.subject == "Receipt ✓" && mapped.sender == "José")
        precondition(mapped.senderEmail == "jose@example.com" && mapped.toRecipients == ["me@example.com"])
        precondition(mapped.paragraphs == ["Hello café", "Here is your receipt."])
        precondition(mapped.preview == "Hello & receipt" && mapped.isUnread && mapped.isStarred)
        precondition(mapped.providerMessageID == "abc123" && mapped.providerThreadID == "thread123")
        precondition(mapped.attachments[0].providerMessageID == "abc123" && mapped.attachments[0].providerAttachmentID == "attachment123")
        precondition(mapped.id == GmailMessageMapper.message(wire, accountEmail: "me@example.com").id)
        precondition(mapped.id != GmailMessageMapper.message(wire, accountEmail: "other@example.com").id)
        let nestedJSON: [String:Any] = ["id":"nested123", "threadId":"nestedthread", "payload":["mimeType":"multipart/mixed", "parts":[
            ["partId":"0", "mimeType":"text/plain", "body":["data":GmailEncoding.base64URL(Data("Parent body".utf8))]],
            ["partId":"1", "mimeType":"message/rfc822", "filename":"forwarded.eml", "body":["attachmentId":"emlfile"], "parts":[
                ["partId":"1.0", "mimeType":"text/plain", "body":["data":GmailEncoding.base64URL(Data("Private attachment body".utf8))]],
                ["partId":"1.1", "mimeType":"application/pdf", "filename":"nested.pdf", "body":["attachmentId":"nestedfile"]]]],
            ["partId":"2", "mimeType":"text/plain", "headers":[["name":"Content-Disposition", "value":"attachment"]], "body":["attachmentId":"namelessfile"]]
        ]]]
        let nestedWire = try JSONDecoder().decode(GmailWireMessage.self, from:JSONSerialization.data(withJSONObject:nestedJSON))
        let nestedMail = GmailMessageMapper.message(nestedWire, accountEmail:"me@example.com")
        precondition(nestedMail.paragraphs == ["Parent body"])
        precondition(nestedMail.attachments.count == 2 && nestedMail.attachments[0].name == "forwarded.eml")
        precondition(nestedMail.attachments[1].name.hasPrefix("Attachment") && nestedMail.attachments[1].providerAttachmentID == "namelessfile")
        precondition(!nestedMail.attachments.contains { $0.name == "nested.pdf" })
        print("PASS: nested attached messages stay separate; unnamed Content-Disposition attachments are preserved")
        let htmlText = GmailEncoding.plainText(fromHTML: html)
        precondition(!htmlText.contains("bad") && !htmlText.contains("https:") && htmlText.contains("Receipt & notes 😊"))
        precondition(GmailEncoding.decodeBase64URL(GmailEncoding.base64URL(Data([0, 255, 13, 42]))) == Data([0, 255, 13, 42]))
        let oauth = try GoogleDesktopOAuth.authorizationURL(clientID: "fixture.apps.googleusercontent.com", redirect: URL(string:"http://127.0.0.1:12345/")!, state:"fixture-state", verifier:"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let query = URLComponents(url: oauth, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.first { $0.name == "code_challenge" }?.value == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = try GoogleDesktopOAuth.randomValue()
        precondition(random.count == 43 && !random.contains("="))
        print("PASS: Gmail payload, MIME part, address, Unicode header, attachment, stable-ID, safe-text, and PKCE fixtures")

        let outgoing = GmailOutgoingMail(from:"me@example.com", displayName:"Míriam", to:["friend@example.com"], cc:["team@example.com"], bcc:["private@example.com"],
            subject:"A long café subject with ✓ and emoji 😊 that spans encoded words safely", plainText:"Hello café\n\nSecond paragraph", html:"<p>Hello café</p>",
            messageID:"<new@example.com>", inReplyTo:"<prior@example.com>", references:["<old@example.com>","<prior@example.com>"],
            attachments:[.init(name:"résumé.pdf", mimeType:"application/pdf", data:Data([0,1,2,3,255]))])
        let encoded = try GmailMIME.encode(outgoing, now: Date(timeIntervalSince1970: 1700000000))
        let mimePath = ProcessInfo.processInfo.environment["POSTMERE_FIXTURE_MIME_PATH"] ?? "/private/tmp/PostmereGmailFixture.eml"
        try encoded.write(to: URL(fileURLWithPath:mimePath))
        let invalid = GmailOutgoingMail(from:"me@example.com", displayName:"Me", to:["friend@example.com"], cc:[], bcc:[], subject:"Subject\r\nBcc: injected@example.com", plainText:"", html:nil, messageID:"<new@example.com>", inReplyTo:nil, references:[], attachments:[])
        do { _ = try GmailMIME.encode(invalid); preconditionFailure("Header injection accepted") } catch GmailError.invalidMessage { }
        print("PASS: RFC822/MIME generation and header injection rejection; inert EML ready for independent parser")

        let syncCalls = FixtureRecorder()
        GmailFixtureProtocol.handler = { request in
            _ = syncCalls.record(request)
            if request.url!.path.hasSuffix("/messages") { return (200, Data(#"{"messages":[{"id":"abc123","threadId":"thread123"}],"nextPageToken":"older"}"#.utf8)) }
            if request.url!.path.hasSuffix("/messages/abc123") { return (200, wireData) }
            if request.url!.path.hasSuffix("/messages/deleted123") { return (404, Data(#"{"error":{"message":"Not Found"}}"#.utf8)) }
            throw URLError(.unsupportedURL)
        }
        let synced = try await api.sync(maximumMessages:1)
        precondition(synced.messages.count == 1 && synced.hasMore)
        precondition(syncCalls.count("/gmail/v1/users/me/messages") == 1)
        print("PASS: bounded Gmail listing + detail fetch with explicit pagination")
        let verified = try await api.verify(messageIDs:["abc123", "deleted123"], expectedAccountEmail:"me@example.com")
        precondition(verified.messages.map(\.id) == ["abc123"] && verified.unavailableMessageIDs == ["deleted123"])
        GmailFixtureProtocol.handler = { _ in (403, Data(#"{"error":{"message":"Permission denied"}}"#.utf8)) }
        do {
            _ = try await api.verify(messageIDs:["abc123"], expectedAccountEmail:"me@example.com")
            preconditionFailure("Permission failure was treated as a verified deletion")
        } catch GmailError.http(403, _) { }
        print("PASS: older valid mail survives bounded sync; only explicit404 marks unavailable, never403")

        let refreshCalls = FixtureRecorder()
        GmailFixtureProtocol.handler = { request in
            let count = refreshCalls.record(request)
            if request.url!.path == "/token" { return (200, Data(#"{"access_token":"refreshed-access","expires_in":3600,"token_type":"Bearer"}"#.utf8)) }
            if request.url!.path.hasSuffix("/profile") {
                if count == 1 { return (401, Data(#"{"error":{"message":"Expired"}}"#.utf8)) }
                precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer refreshed-access")
                return (200, Data(#"{"emailAddress":"me@example.com","messagesTotal":1}"#.utf8))
            }
            throw URLError(.unsupportedURL)
        }
        _ = try await api.profile()
        precondition(refreshCalls.count("/token") == 1 && refreshCalls.count("/gmail/v1/users/me/profile") == 2)
        let storedAfterRefresh = await storage.load()
        precondition(storedAfterRefresh?.refreshToken == "fixture-refresh" && storedAfterRefresh?.accessToken == "refreshed-access")
        print("PASS: exactly one 401 refresh/retry and refresh-token preservation")

        let modificationCalls = FixtureRecorder()
        GmailFixtureProtocol.handler = { request in
            _ = modificationCalls.record(request)
            precondition(request.httpMethod == "POST" && request.url!.path.hasSuffix("/modify"))
            return (200, Data(#"{"id":"abc123","threadId":"thread123","labelIds":["STARRED"]}"#.utf8))
        }
        try await api.modifyLabels(messageID:"abc123", add:["STARRED"], remove:["UNREAD"])
        precondition(modificationCalls.count("/gmail/v1/users/me/messages/abc123/modify") == 1)
        print("PASS: label modification reaches the expected authenticated Gmail endpoint")
        do {
            try await api.modifyLabels(messageID:"abc123", add:["STARRED"], remove:[], expectedAccountEmail:"other@example.com")
            preconditionFailure("Cross-account mutation was allowed")
        } catch GmailError.invalidMessage { }
        precondition(modificationCalls.count("/gmail/v1/users/me/messages/abc123/modify") == 1)
        print("PASS: cross-account mutations are blocked before any API request")

        let sendCalls = FixtureRecorder()
        GmailFixtureProtocol.handler = { request in _ = sendCalls.record(request); return (503, Data(#"{"error":{"message":"Unavailable"}}"#.utf8)) }
        do { _ = try await api.send(raw:encoded, threadID:nil); preconditionFailure("503 send was reported successful") } catch GmailError.sendUnconfirmed { }
        precondition(sendCalls.count("/gmail/v1/users/me/messages/send") == 1)
        print("PASS: ambiguous send failure is surfaced and never retried")

        GmailFixtureProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do { _ = try await api.profile(); preconditionFailure("Malformed response accepted") } catch GmailError.invalidResponse { }
        print("PASS: malformed successful HTTP response is rejected")

        let invalidStorage = MemoryGmailCredentials(credential)
        let invalidAPI = GmailAPIClient(storage:invalidStorage, session:session)
        GmailFixtureProtocol.handler = { request in
            if request.url!.path == "/token" { return (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
            return (401, Data(#"{"error":{"message":"Revoked"}}"#.utf8))
        }
        do { _ = try await invalidAPI.profile(); preconditionFailure("Revoked token accepted") } catch GmailError.notConnected { }
        let revokedInfo = try await invalidAPI.connectionInfo()
        precondition(revokedInfo?.hasTokens == false)
        print("PASS: revoked refresh token leaves an explicitly disconnected account")
        session.invalidateAndCancel()
        if CommandLine.arguments.contains("--loopback") {
            let server = GoogleOAuthLoopback()
            let redirect = try await server.start(state:"expected-state")
            precondition(redirect.host == "127.0.0.1" && redirect.port != nil)
            let localSession = URLSession(configuration:.ephemeral)
            let (_, rejected) = try await localSession.data(from:URL(string:"?state=wrong-state&code=ignored", relativeTo:redirect)!.absoluteURL)
            precondition((rejected as? HTTPURLResponse)?.statusCode == 400)
            let callbackTask = Task { try await server.authorizationCode() }
            let (_, accepted) = try await localSession.data(from:URL(string:"?state=expected-state&code=fixture-code", relativeTo:redirect)!.absoluteURL)
            precondition((accepted as? HTTPURLResponse)?.statusCode == 200)
            let code = try await callbackTask.value
            precondition(code == "fixture-code")
            localSession.invalidateAndCancel()
            let cancelledServer = GoogleOAuthLoopback()
            _ = try await cancelledServer.start(state:"cancel-state")
            await cancelledServer.cancel()
            do { _ = try await cancelledServer.authorizationCode(); preconditionFailure("Cancelled callback succeeded") } catch GmailError.cancelled { }
            print("PASS: real loopback rejects incorrect OAuth state, accepts the matching callback, closes, and cancels")
        }
        print("All fixture checks passed. No request reached Google; no live email was sent and no real Keychain item was accessed.")
    }
}
