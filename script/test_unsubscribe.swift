import Foundation

nonisolated final class UnsubscribeFixtureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var stopped = 0
    func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    func stop() { lock.lock(); defer { lock.unlock() }; stopped += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }
}

nonisolated final class UnsubscribeFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, UnsubscribeFixtureProtocol) throws -> Void)!
    nonisolated(unsafe) static var recorder = UnsubscribeFixtureRecorder()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.recorder.record(request)
        do { try Self.handler(request, self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.recorder.stop() }
    func respond(_ status: Int, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("This body is not rendered or interpreted.".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct UnsubscribeFixtures {
    static let endpoint = "https://lists.example.com/unsubscribe?opaque=fixture-token"

    static func headers(_ list: String = "<https://lists.example.com/unsubscribe?opaque=fixture-token>") -> MailUnsubscribeHeaders {
        .init(listUnsubscribe: [list], listUnsubscribePost: ["List-Unsubscribe=One-Click"],
              authenticationResults: ["mx.google.com; dkim=pass header.i=@example.com header.s=mail header.b=abcdefgh"],
              dkimSignatures: ["v=1; a=rsa-sha256; d=example.com; s=mail; h=from:subject:list-unsubscribe:list-unsubscribe-post; b=abcdefgh0123456789; bh=fixture"], source: "gmail")
    }

    static func message(_ headers: MailUnsubscribeHeaders = headers()) -> MailMessage {
        MailMessage(sender: "Fixture newsletter", senderEmail: "news@example.com", initials: "FN", subject: "Fixture",
                    preview: "", paragraphs: ["Fixture"], timeLabel: "Now", account: "remote:fixture:newsletter", toRecipients: ["me@example.com"],
                    providerMessageID: "fixture-message", providerAccountEmail: "me@example.com", unsubscribeHeaders: headers)
    }

    static func options(_ headers: MailUnsubscribeHeaders) -> MailUnsubscribeOptions {
        MailUnsubscribeService.options(for: message(headers))
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnsubscribeFixtureProtocol.self]
        // These must be removed even if a caller supplies a configured session.
        config.httpAdditionalHeaders = ["Authorization": "Bearer must-not-leak", "Cookie": "fixture=must-not-leak"]
        return config
    }

    static func service(addresses: [String] = ["93.184.216.34"]) -> MailUnsubscribeService {
        MailUnsubscribeService(configuration: configuration(), resolveHost: { _ in addresses })
    }

    @MainActor static func main() async throws {
        parserFixtures()
        try modelFixtures()
        try await networkFixtures()
        print("PASS: all unsubscribe fixtures; no real DNS, requests, mail or subscriptions")
    }

    static func parserFixtures() {
        let standard = options(headers())
        precondition(standard.oneClickURL == nil && standard.isAvailable)
        precondition(standard.methods == [.web(URL(string: endpoint)!)])

        let ordered = options(headers("(Use this (nested) command) <mailto:list-off@example.com?subject=unsubscribe>,\r\n\t<https://lists.example.com/unsubscribe?opaque=fixture-token> (web)"))
        precondition(ordered.methods.count == 2 && ordered.oneClickURL == nil)
        guard case .email(let email) = ordered.methods[0] else { preconditionFailure("RFC preference order lost") }
        precondition(email.recipients == ["list-off@example.com"] && email.subject == "unsubscribe")
        let spaced = options(headers("<https://lists.example.com/\r\n unsubscribe?opaque=fixture-token>"))
        precondition(spaced.oneClickURL == nil && spaced.methods == [.web(URL(string: endpoint)!)])
        precondition(options(headers("mailto:list@example.com")).methods.isEmpty)
        precondition(options(headers("<mailto:list@example.com>, bare-invalid, <https://lists.example.com/unsubscribe>")).methods.count == 1)
        precondition(options(headers("<mailto:list@example.com> ignored <https://lists.example.com/unsubscribe>")).methods.count == 1)
        precondition(options(headers("(unclosed <mailto:list@example.com>")).methods.isEmpty)
        precondition(options(headers("<https://lists.example.com/a>\nInjected: <https://evil.example.com>")).methods.isEmpty)

        var duplicate = headers(); duplicate.listUnsubscribe.append("<mailto:other@example.com>")
        precondition(!options(duplicate).isAvailable)
        var postDuplicate = headers(); postDuplicate.listUnsubscribePost.append("List-Unsubscribe=One-Click")
        precondition(options(postDuplicate).oneClickURL == nil && options(postDuplicate).isAvailable)
        var malformedPost = headers(); malformedPost.listUnsubscribePost = ["List-Unsubscribe=One-Click&other=value"]
        precondition(options(malformedPost).oneClickURL == nil)
        precondition(options(headers("<https://lists.example.com/a>, <https://lists.example.com/b>")).oneClickURL == nil)
        precondition(options(headers("<http://lists.example.com/a>")).oneClickURL == nil)
        precondition(options(headers("<http://lists.example.com/a>")).isAvailable)
        precondition(options(headers("<https://lists.example.com/bad%>")).oneClickURL == nil)
        var noPost = headers(); noPost.listUnsubscribePost = []
        precondition(options(noPost).oneClickURL == nil && options(noPost).isAvailable)

        var unsigned = headers(); unsigned.dkimSignatures = []
        precondition(options(unsigned).oneClickURL == nil && options(unsigned).methods.count == 1)
        var noCoverage = headers(); noCoverage.dkimSignatures[0] = noCoverage.dkimSignatures[0].replacingOccurrences(of: ":list-unsubscribe-post", with: "")
        precondition(options(noCoverage).oneClickURL == nil)
        var ambiguousSignature = noCoverage
        ambiguousSignature.dkimSignatures.append(headers().dkimSignatures[0].replacingOccurrences(of: "abcdefgh0123456789", with: "abcdefghForgedSignature"))
        precondition(options(ambiguousSignature).oneClickURL == nil, "A forged signature must not borrow another signature's reported prefix")
        var failed = headers(); failed.authenticationResults[0] = failed.authenticationResults[0].replacingOccurrences(of: "dkim=pass", with: "dkim=fail")
        precondition(options(failed).oneClickURL == nil)
        var fakePass = headers(); fakePass.authenticationResults = ["attacker.example.com; dkim=pass header.i=@example.com header.s=mail header.b=abcdefgh"]
        precondition(options(fakePass).oneClickURL == nil)
        var wrongSignature = headers(); wrongSignature.authenticationResults[0] = wrongSignature.authenticationResults[0].replacingOccurrences(of: "header.b=abcdefgh", with: "header.b=notmatches")
        precondition(options(wrongSignature).oneClickURL == nil)
        var wrongDomain = headers(); wrongDomain.authenticationResults[0] = wrongDomain.authenticationResults[0].replacingOccurrences(of: "@example.com", with: "@elsewhere.com")
        precondition(options(wrongDomain).oneClickURL == nil)
        var duplicateAuth = headers(); duplicateAuth.authenticationResults.append(duplicateAuth.authenticationResults[0])
        precondition(options(duplicateAuth).oneClickURL == nil)
        var ignoredComment = headers(); ignoredComment.authenticationResults = ["mx.google.com; dkim=fail (dkim=pass header.i=@example.com header.s=mail header.b=abcdefgh)"]
        precondition(options(ignoredComment).oneClickURL == nil)
        var local = message(); local.account = "Work"
        precondition(MailUnsubscribeService.options(for: local).oneClickURL == nil)
        var outgoing = message(); outgoing.isOutgoing = true
        precondition(!MailUnsubscribeService.options(for: outgoing).isAvailable)

        let decoded = MailUnsubscribeParser.emailTarget("mailto:list+remove@example.com?subject=Unsubscribe%20caf%C3%A9&body=Remove%20me%0D%0AThank%20you")
        precondition(decoded == .init(recipients: ["list+remove@example.com"], subject: "Unsubscribe café", body: "Remove me\r\nThank you"))
        for bad in ["mailto:list@example.com?cc=other@example.com", "mailto:list@example.com?bcc=other@example.com",
                    "mailto:list@example.com?subject=x%0D%0ABcc:y@example.com", "mailto:list@example.com?subject=a&subject=b",
                    "mailto:list@example.com%0AInjected", "mailto://list@example.com", "mailto:a@example.com,b@example.com",
                    "mailto:list@localhost", "mailto:list@example.com?attachment=/private/file"] {
            precondition(MailUnsubscribeParser.emailTarget(bad) == nil, "Unsafe mailto accepted: \(bad)")
        }

        for bad in ["http://127.0.0.1/", "https://10.1.2.3/", "https://2130706433/", "https://0x7f000001/", "https://[::1]/",
                    "https://[::ffff:127.0.0.1]/", "https://localhost/", "https://router.local/", "https://private.internal/",
                    "https://example.com:8080/", "https://user:secret@example.com/", "https://example.com/#token",
                    "https://example.com/%0d%0aInjected", "https://example.com\\@127.0.0.1/", "file:///private/file",
                    "javascript:alert(1)", "data:text/html,test", "ftp://example.com/file", "https://example.com/bad%"] {
            precondition(MailUnsubscribeURLPolicy.webURL(bad) == nil, "Unsafe URL accepted: \(bad)")
        }
        precondition(MailUnsubscribeURLPolicy.webURL("https://lists.example.com:443/unsubscribe") != nil)
        for address in ["127.0.0.1", "10.2.3.4", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.1.2", "198.19.1.2",
                        "0.0.0.0", "224.0.0.1", "192.0.2.1", "198.51.100.2", "203.0.113.1", "::1", "::", "fe80::1", "fc00::1",
                        "::ffff:127.0.0.1", "64:ff9b::7f00:1", "2001:db8::1", "2002:7f00:1::", "3fff::1"] {
            precondition(!MailUnsubscribeURLPolicy.isPublicAddress(address), "Nonpublic address accepted: \(address)")
        }
        for address in ["93.184.216.34", "8.8.8.8", "2001:4860:4860::8888", "2606:4700:4700::1111"] {
            precondition(MailUnsubscribeURLPolicy.isPublicAddress(address))
        }
        precondition(UnsubscribeFixtureProtocol.recorder.count == 0, "Inspection performed a request")
        print("PASS: RFC 2369 parsing, ordered fallbacks, manual choices with cryptographic verification required, header injection, unsafe URLs and private-address policies")
    }

    static func modelFixtures() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let original = message()
        let encoded = try encoder.encode(original)
        let restored = try decoder.decode(MailMessage.self, from: encoded)
        precondition(restored.unsubscribeHeaders == original.unsubscribeHeaders)
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        old.removeValue(forKey: "unsubscribeHeaders")
        let oldMessage = try decoder.decode(MailMessage.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(oldMessage.unsubscribeHeaders == nil)

        let source = headers()
        let account = UUID()
        let identity = RemoteAccountIdentity(localID: "remote:fixture:\(account.uuidString)", accountID: account,
            scope: "fixture", email: "me@example.com", displayName: "Me", provider: "gmail")
        let wire = BackendMailMessage(id: UUID(), accountId: account, providerMessageId: "fixture",
            providerThreadId: "thread", subject: "Fixture", from: BackendAddress(name: "List", email: "news@example.com"),
            to: [BackendAddress(email: "me@example.com")], cc: [], bcc: [], textBody: "Fixture", htmlBody: nil,
            preview: "Fixture", sentAt: .now, isRead: false, isStarred: false, mailbox: "inbox",
            providerLabels: ["INBOX", "CATEGORY_PROMOTIONS"], attachments: [],
            listUnsubscribe: source.listUnsubscribe, listUnsubscribePost: source.listUnsubscribePost)
        let mapped = wire.localMessage(identity: identity)
        precondition(mapped.unsubscribeHeaders?.listUnsubscribe == source.listUnsubscribe)
        precondition(mapped.unsubscribeHeaders?.listUnsubscribePost == source.listUnsubscribePost)
        precondition(mapped.unsubscribeHeaders?.authenticationResults.isEmpty == true)
        precondition(mapped.unsubscribeHeaders?.dkimSignatures.isEmpty == true)
        precondition(mapped.unsubscribeHeaders?.source == identity.provider)
        precondition(mapped.backendMessageID == wire.id && mapped.account == identity.localID)
        precondition(mapped.providerLabelIDs.contains("CATEGORY_PROMOTIONS"))
        precondition(MailUnsubscribeService.options(for: mapped).oneClickURL == nil)
        print("PASS: workspace list metadata and provider labels retained without treating copied authentication headers as proof; pre-feature mailbox JSON decodes unchanged")
    }

    static func networkFixtures() async throws {
        let recorder = UnsubscribeFixtureRecorder()
        UnsubscribeFixtureProtocol.recorder = recorder
        UnsubscribeFixtureProtocol.handler = { _, fixture in fixture.respond(204) }
        let client = service()
        _ = MailUnsubscribeService.options(for: message())
        precondition(recorder.count == 0)
        let browserURL = try await client.validateBrowserURL(URL(string: endpoint)!)
        precondition(browserURL.absoluteString == endpoint && recorder.count == 0, "Browser validation fetched its URL")
        do { try await client.requestOneClick(for: message()); preconditionFailure("Forged authentication headers authorized a POST") }
        catch MailUnsubscribeError.unsupported { }
        precondition(recorder.count == 0, "Unverified native metadata caused a request")
        let privateClient = service(addresses: ["93.184.216.34", "127.0.0.1"])
        do { _ = try await privateClient.validateBrowserURL(URL(string: endpoint)!); preconditionFailure("Private browser destination accepted") }
        catch MailUnsubscribeError.unsafeDestination { }
        let emptyClient = service(addresses: [])
        do { _ = try await emptyClient.validateBrowserURL(URL(string: endpoint)!); preconditionFailure("Empty DNS accepted") }
        catch MailUnsubscribeError.unresolvedHost { }
        precondition(recorder.count == 0)
        print("PASS: forged receiver headers cannot authorize native one-click POSTs; browser validation rejects private or missing DNS without fetching")
    }
}
