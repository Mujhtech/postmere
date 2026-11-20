import Foundation

nonisolated final class BackendFixtureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var stops = 0
    func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    func stop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
}

nonisolated final class BackendFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, BackendFixtureProtocol) -> Void)!
    nonisolated(unsafe) static var recorder = BackendFixtureRecorder()
    private var activeRecorder: BackendFixtureRecorder?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let recorder = Self.recorder
        activeRecorder = recorder
        recorder.record(request)
        Self.handler(request, self)
    }
    override func stopLoading() { activeRecorder?.stop() }
    func response(_ status: Int, headers: [String: String] = [:], body: Data = Data(), finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}

nonisolated struct BackendFixtureDTO: Codable, Sendable {
    let accountId: UUID
    let displayName: String
    let sentAt: Date
    let isRead: Bool
}
nonisolated struct BackendFixtureBody: Encodable, Sendable {
    let workspaceId: UUID
    let textBody: String
    let scheduledAt: Date
}
nonisolated struct BackendFixtureFailure: Error, CustomStringConvertible {
    let description: String
}

// URLProtocol starts delivery off the main actor. The test resumes it once after receiving the first delta.
nonisolated struct BackendStreamHandle: @unchecked Sendable {
    let fixture: BackendFixtureProtocol
}

@main
struct BackendClientFixtures {
    @MainActor static var failures: [String] = []
    nonisolated static let accountID = UUID(uuidString: "005a14d1-0f6b-4119-b8fe-1afe543f0756")!
    nonisolated static let dto = Data("""
        {"account_id":"005a14d1-0f6b-4119-b8fe-1afe543f0756","display_name":"Team inbox","sent_at":"2026-11-17T12:34:56.123456Z","is_read":true}
        """.utf8)

    static func configuration(ambient: Bool = false) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendFixtureProtocol.self]
        if ambient { config.httpAdditionalHeaders = ["Authorization": "Bearer ambient-secret", "Cookie": "ambient=secret", "X-Ambient": "remove-me"] }
        return config
    }
    static func client(ambient: Bool = false) throws -> BackendHTTPClient {
        try BackendHTTPClient(baseURL: "https://postmere.example.com", configuration: configuration(ambient: ambient))
    }
    static func reset(_ handler: @escaping @Sendable (URLRequest, BackendFixtureProtocol) -> Void) -> BackendFixtureRecorder {
        let recorder = BackendFixtureRecorder()
        BackendFixtureProtocol.recorder = recorder
        BackendFixtureProtocol.handler = handler
        return recorder
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
    static func error(_ name: String, matches: (Error) -> Bool, operation: () async throws -> Void) async {
        do { try await operation(); failures.append("\(name): expected an error") }
        catch { if !matches(error) { failures.append("\(name): wrong error type: \(type(of: error))") } }
    }

    @MainActor static func main() async throws {
        baseURLFixtures()
        progress("Checking request encoding")
        try await requestFixtures()
        progress("Checking responses and redirects")
        try await responseFixtures()
        progress("Checking sender-profile requests")
        try await senderProfileFixtures()
        progress("Checking progressive summaries")
        try await summaryFixtures()
        progress("Checking response size limits")
        try await sizeFixtures()
        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            throw BackendFixtureFailure(description: "\(failures.count) backend client checks failed")
        }
        print("PASS: backend base URL policy, scoped paths, explicit auth, escaped queries, JSON bodies, snake_case DTOs and fractional timestamps")
        print("PASS: sanitized HTTP/decode errors, redirect rejection and declared/streaming size limits")
        print("PASS: all requests intercepted by URLProtocol; no real server or provider contacted")
    }
    static func progress(_ message: String) { FileHandle.standardError.write(Data("\(message)\n".utf8)) }

    static func baseURLFixtures() {
        for value in ["https://postmere.example.com", " https://postmere.example.com/ \n", "https://postmere.example.com:8443", "http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080"] {
            do { _ = try BackendHTTPClient(baseURL: value, configuration: configuration()) }
            catch { failures.append("Valid server URL rejected: \(value)") }
        }
        for value in ["http://postmere.example.com", "http://127.0.0.2", "ftp://postmere.example.com", "file:///tmp/server", "https://user:password@postmere.example.com", "https://postmere.example.com/path", "https://postmere.example.com?token=secret", "https://postmere.example.com#fragment", "not a URL", "https://"] {
            do { _ = try BackendHTTPClient(baseURL: value, configuration: configuration()); failures.append("Invalid server URL accepted: \(value)") }
            catch is BackendError {} catch { failures.append("Wrong error for invalid server URL") }
        }
    }

    static func requestFixtures() async throws {
        let recorder = reset { _, fixture in fixture.response(200, body: dto) }
        let transport = try client()
        let query = "from:person+tag@example.com & subject:\"Café #1\""
        let result: BackendFixtureDTO = try await transport.request("GET", "/v1/mail/messages", token: "explicit-fixture-token",
            query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "cursor", value: "a+b/c==")])
        check(result.accountId == accountID && result.displayName == "Team inbox" && result.isRead, "snake_case DTO fields did not decode")
        let expectedDate = Date(timeIntervalSince1970: 1_794_918_896.123456)
        check(abs(result.sentAt.timeIntervalSince1970 - expectedDate.timeIntervalSince1970) < 0.001, "fractional timestamp lost precision or changed timezone")
        let request = recorder.last!
        check(request.url?.host == "postmere.example.com" && request.url?.path == "/v1/mail/messages", "Request escaped configured server origin/path")
        check(request.httpMethod == "GET", "HTTP method changed")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer explicit-fixture-token", "Explicit bearer header is missing")
        check(request.value(forHTTPHeaderField: "Accept") == "application/json", "JSON accept header is missing")
        let encoded = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedQuery!
        check(encoded.contains("%2B") && !encoded.contains("+"), "Literal query '+' must be percent-encoded for server query parsers")
        check(encoded.contains("%26") && encoded.contains("%23"), "Query delimiters were not percent-encoded")
        let decoded = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(decoded.first?.value == query && decoded.last?.value == "a+b/c==", "Query values changed during encoding")

        let payload = BackendFixtureBody(workspaceId: accountID, textBody: "Hello café\n{{name}}", scheduledAt: Date(timeIntervalSince1970: 1_794_918_896))
        let _: BackendFixtureDTO = try await transport.request("POST", "/v1/mail/outbox", token: "explicit-fixture-token", body: payload)
        let post = recorder.last!
        let body = try JSONSerialization.jsonObject(with: body(post)) as! [String: Any]
        check(post.httpMethod == "POST" && post.value(forHTTPHeaderField: "Content-Type") == "application/json", "JSON POST headers are incorrect")
        check(body["workspace_id"] as? String == accountID.uuidString && body["text_body"] as? String == payload.textBody, "Encodable body did not use snake_case or preserve text")
        check(body["scheduled_at"] as? String == "2026-11-17T12:34:56Z", "Body timestamp is not ISO8601")

        let ambientRecorder = reset { _, fixture in fixture.response(200, body: dto) }
        let supplied = configuration(ambient: true)
        supplied.urlCache = URLCache(memoryCapacity: 1234, diskCapacity: 0, diskPath: nil)
        let ambientClient = try BackendHTTPClient(baseURL: "https://postmere.example.com", configuration: supplied)
        let _: BackendFixtureDTO = try await ambientClient.request("POST", "/v1/auth/login", body: payload)
        let login = ambientRecorder.last!
        check(login.value(forHTTPHeaderField: "Authorization") == nil && login.value(forHTTPHeaderField: "Cookie") == nil && login.value(forHTTPHeaderField: "X-Ambient") == nil,
              "Ambient configuration headers leaked into unauthenticated request")
        check(supplied.httpAdditionalHeaders?["Authorization"] as? String == "Bearer ambient-secret", "Client mutated caller's supplied configuration")
        check(supplied.urlCache?.memoryCapacity == 1234, "Client mutated caller's supplied cache configuration")

        for path in ["https://attacker.example.com/v1/mail/messages", "//attacker.example.com/v1/mail/messages", "/health/live", "/v1/../admin", "/v1/mail?token=x", "/v1/mail#fragment"] {
            await error("Unsafe path", matches: { if case BackendError.invalidURL = $0 { return true }; return false }) { _ = try await transport.raw("GET", path, token: "must-stay-local") }
        }
        check(ambientRecorder.count == 1, "Unsafe path performed an HTTP request")
    }

    static func responseFixtures() async throws {
        let transport = try client()
        _ = reset { _, fixture in fixture.response(204) }
        let _: BackendEmpty = try await transport.request("POST", "/v1/auth/logout", token: "fixture")
        _ = reset { _, fixture in fixture.response(200, body: Data("{\"unexpected\":\"server-secret\"}".utf8)) }
        await error("Malformed DTO", matches: { if case BackendError.invalidResponse = $0 { return true }; return false }) { let _: BackendFixtureDTO = try await transport.request("GET", "/v1/mail/messages") }
        let nonFractional = dto.replacingOccurrences(of: "2026-11-17T12:34:56.123456Z", with: "2026-11-17T12:34:56Z")
        _ = reset { _, fixture in fixture.response(200, body: nonFractional) }
        let response: BackendFixtureDTO = try await transport.request("GET", "/v1/mail/messages")
        check(response.sentAt == Date(timeIntervalSince1970: 1_794_918_896), "Non-fractional ISO8601 response failed")
        for status in [400, 401, 403, 404, 409, 422, 429, 500, 503] {
            _ = reset { _, fixture in fixture.response(status, body: Data("<html>provider-secret sql-password oauth-token</html>".utf8)) }
            await error("HTTP \(status)", matches: { error in
                guard case let BackendError.response(code, text) = error else { return false }
                return code == status && !text.contains("provider-secret") && !text.contains("sql-password") && !text.contains("oauth-token") && !text.contains("<html>")
            }) { _ = try await transport.raw("GET", "/v1/mail/messages") }
        }
        let beforeThrottle = Date.now
        _ = reset { _, fixture in fixture.response(429, headers: ["Retry-After": "900"]) }
        await error("Sync cooldown", matches: {
            guard case BackendError.mailSyncRateLimited(let retryAt) = $0 else { return false }
            return retryAt >= beforeThrottle.addingTimeInterval(900) && retryAt <= Date.now.addingTimeInterval(900)
        }) { _ = try await transport.raw("POST", "/v1/mail/accounts/fixture/sync") }
        let redirected = reset { _, fixture in fixture.response(302, headers: ["Location": "https://attacker.example.com/leak"], body: Data([65])) }
        await error("Redirect", matches: { if case BackendError.redirect = $0 { return true }; return false }) { _ = try await transport.raw("GET", "/v1/mail/messages", token: "must-not-follow") }
        try await Task.sleep(for: .milliseconds(50))
        check(redirected.count == 1, "Redirect caused a second request")
    }

    static func senderProfileFixtures() async throws {
        let transport = try client(ambient: true)
        let path = "/v1/mail/messages/\(accountID.uuidString)/sender-profile"
        let recorder = reset { _, fixture in fixture.response(200, body: Data(#"{"email":"sender@example.com","status":"not_found"}"#.utf8)) }
        let payload = Data(#"{"refresh":true}"#.utf8)
        _ = try await transport.raw("POST", path, token: "explicit-profile-token", body: payload)
        let request = recorder.last!
        check(request.url?.path == path && request.httpMethod == "POST", "Sender-profile lookup must use the message-scoped POST endpoint")
        check(request.timeoutInterval == 115, "Sender-profile lookup must allow the server's bounded enrichment deadline")
        check(body(request) == payload && request.url?.query == nil, "Sender-profile transport must preserve the refresh-only request without appending mail data")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer explicit-profile-token" &&
              request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "X-Ambient") == nil,
              "Sender-profile lookup must keep credentials scoped and remove ambient headers")
        for (status, code, expected) in [(503, "ai_not_configured", BackendAIError.notConfigured),
                                         (504, "ai_timeout", .timeout), (502, "ai_provider_auth", .credentials),
                                         (502, "ai_invalid_output", .invalidOutput), (429, "ai_provider_busy", .busy)] {
            _ = reset { _, fixture in fixture.response(status, body: Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"private-sender provider-key\"}}".utf8)) }
            await error("Sender-profile \(code)", matches: {
                $0 as? BackendAIError == expected && !$0.localizedDescription.contains("private-sender") && !$0.localizedDescription.contains("provider-key")
            }) { _ = try await transport.raw("POST", path, token: "fixture", body: payload) }
        }
        for status in [401, 403] {
            _ = reset { _, fixture in fixture.response(status, body: Data(#"{"error":{"code":"ai_provider_auth","message":"private-sender"}}"#.utf8)) }
            await error("Sender-profile auth \(status)", matches: {
                guard case let BackendError.response(code, message) = $0 else { return false }
                return code == status && !message.contains("private-sender")
            }) { _ = try await transport.raw("POST", path, token: "fixture", body: payload) }
        }
        let unrelated = reset { _, fixture in fixture.response(200, body: Data("{}".utf8)) }
        _ = try await transport.raw("POST", "/v1/mail/messages/\(accountID.uuidString)/other", body: payload)
        check(unrelated.last?.timeoutInterval != 115, "Long enrichment timeout must not affect unrelated mail routes")
        print("PASS: sender-profile scoped POST, bounded enrichment timeout, refresh-only body and sanitized AI/provider errors")
    }

    static func sizeFixtures() async throws {
        let transport = try client()
        _ = reset { _, fixture in fixture.response(200, headers: ["Content-Length": String(40 * 1024 * 1024 + 1)], body: Data([65])) }
        await error("Declared response size", matches: { if case BackendError.tooLarge = $0 { return true }; return false }) { _ = try await transport.raw("GET", "/v1/mail/messages") }
        try await Task.sleep(for: .milliseconds(50))
        _ = reset { _, fixture in fixture.response(200, body: Data(repeating: 65, count: 40 * 1024 * 1024 + 1)) }
        await error("Streaming response size", matches: { if case BackendError.tooLarge = $0 { return true }; return false }) { _ = try await transport.raw("GET", "/v1/mail/messages") }
    }

    static func summaryFixtures() async throws {
        let stream = BackendSummaryStream(baseURL: URL(string: "https://postmere.example.com")!,
                                          configuration: configuration(ambient: true))
        let json = """
            {"text":"Meeting moved to Friday.","items":[{"kind":"date","text":"Friday","source_ids":["\(accountID)"],"action":null,"message_id":null,"due_at":null}],"sources":[{"id":"\(accountID)","account_id":"\(accountID)","subject":"Update","sender":"Ada","sent_at":"2026-11-20T06:30:00Z"}],"scope":"Selected messages","generated_at":"2026-11-20T06:30:00.123456789Z","model":"fixture"}
            """
        let fixtureStream = AsyncStream.makeStream(of: BackendStreamHandle.self)
        let recorder = reset { _, fixture in
            fixture.response(200, headers: ["Content-Type":"text/event-stream"],
                             body: Data("data: {\"type\":\"delta\",\"text\":\"Meeting moved\"}\r\n\r\n".utf8), finish: false)
            fixtureStream.continuation.yield(BackendStreamHandle(fixture: fixture))
            fixtureStream.continuation.finish()
        }
        var chunks: [String] = []
        let task = Task {
            try await stream.generate(messageIDs: [accountID], token: "fixture") { chunks.append($0) }
        }
        for await handle in fixtureStream.stream {
            let fixture = handle.fixture
            for _ in 0..<200 where chunks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
            check(chunks == ["Meeting moved"], "First chunk must appear before the result is available")
            let second = Data("data: {\"type\":\"delta\",\"text\":\" to Friday.\"}\n\ndata: {\"type\":\"done\",\"result\":\(json)}\n\n".utf8)
            fixture.client?.urlProtocol(fixture, didLoad: second.prefix(7))
            fixture.client?.urlProtocol(fixture, didLoad: second.dropFirst(7))
            fixture.client?.urlProtocolDidFinishLoading(fixture)
        }
        let result = try await task.value
        let request = recorder.last!
        check(recorder.count == 1 && request.httpMethod == "POST" && request.url?.path == "/v1/ai/summary", "Stream must use a single generation request")
        check(request.value(forHTTPHeaderField: "Accept") == "text/event-stream" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture", "Stream headers")
        check(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "X-Ambient") == nil, "Stream included ambient headers")
        check(chunks.joined() == result.text && result.items.first?.sourceIds == [accountID] && result.sources.first?.id == accountID, "Completed summary and citations")

        let openRequest = reset { _, fixture in
            fixture.response(200, headers: ["Content-Type": "text/event-stream"],
                             body: Data("data: {\"type\":\"delta\",\"text\":\"Pending\"}\n\n".utf8), finish: false)
        }
        var receivedPartial = false
        let pending = Task {
            try await stream.generate(messageIDs: [accountID], token: "fixture") { _ in receivedPartial = true }
        }
        for _ in 0..<200 where !receivedPartial { try await Task.sleep(for: .milliseconds(5)) }
        check(receivedPartial, "Expected a partial summary before cancellation")
        pending.cancel()
        switch await pending.result {
        case .success: failures.append("Cancelled stream produced a finished summary")
        case .failure: break
        }
        for _ in 0..<200 where openRequest.stopCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        check(openRequest.stopCount > 0 && openRequest.count == 1, "Cancelling must close the active request without resubmitting")

        let legacy = reset { _, fixture in
            fixture.response(200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        }
        let oldResult = try await stream.generate(messageIDs: [accountID], token: "fixture") { _ in failures.append("Legacy JSON emitted a synthetic delta") }
        check(legacy.count == 1 && oldResult.text == result.text, "Legacy JSON must complete without resubmitting")

        _ = reset { _, fixture in fixture.response(200, headers: ["Content-Type":"text/event-stream"],
             body: Data("data: {\"type\":\"delta\",\"text\":\"Partial\"}\n\n".utf8)) }
        await error("Stream closed before done", matches: { $0 as? BackendAIError == .incomplete }) {
            _ = try await stream.generate(messageIDs: [accountID], token: "fixture") { _ in }
        }
        _ = reset { _, fixture in fixture.response(200, headers: ["Content-Type":"text/event-stream"],
             body: Data("data: {\"type\":\"error\",\"code\":\"ai_invalid_output\",\"message\":\"private data\"}\n\n".utf8)) }
        await error("Server validation failure", matches: { $0 as? BackendAIError == .invalidOutput && !$0.localizedDescription.contains("private data") }) {
            _ = try await stream.generate(messageIDs: [accountID], token: "fixture") { _ in }
        }
        for (status, code, expected) in [(503,"unavailable",BackendAIError.unavailable), (504,"ai_timeout",.timeout), (502,"ai_provider_auth",.credentials)] {
            _ = reset { _, fixture in fixture.response(status,
                 body: Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"private data\"}}".utf8)) }
            await error("AI failure \(code)", matches: { $0 as? BackendAIError == expected }) {
                _ = try await stream.generate(messageIDs: [accountID], token: "fixture") { _ in }
            }
        }
    }
}

nonisolated private extension Data {
    func replacingOccurrences(of source: String, with target: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: source, with: target).utf8)
    }
}
