import Foundation

nonisolated enum BackendError: LocalizedError, Sendable {
    case invalidURL, insecureURL, redirect, invalidResponse, tooLarge, notConnected
    case response(Int, String)
    case mailSyncRateLimited(retryAt: Date)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter the server’s base URL without a query, fragment, or password."
        case .insecureURL: "Use HTTPS for your Postmere server. Local development can use loopback HTTP."
        case .redirect: "The server redirected this request. Check your workspace server address."
        case .invalidResponse: "The server returned an unreadable response."
        case .tooLarge: "The server response exceeded the size limit."
        case .notConnected: "Sign in to your Postmere workspace to continue."
        case let .response(_, message): message
        case .mailSyncRateLimited: "Mail sync is paused and will retry automatically."
        }
    }
}

nonisolated struct BackendEmpty: Codable, Sendable {}

nonisolated enum BackendAIError: String, LocalizedError {
    case notConfigured = "ai_not_configured"
    case credentials = "ai_provider_auth"
    case request = "ai_provider_request"
    case busy = "ai_provider_busy"
    case unavailable = "ai_provider_unavailable"
    case timeout = "ai_timeout"
    case incomplete = "ai_incomplete"
    case invalidOutput = "ai_invalid_output"
    case refused = "ai_refused"

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Your workspace administrator needs to configure an AI provider."
        case .credentials: "The AI provider denied access. Ask your workspace administrator to check the API key and model access."
        case .request: "The AI provider rejected the request. Ask your administrator to check the configured model."
        case .busy: "The AI provider reached a usage limit. Try again later."
        case .unavailable: "AI assistance is temporarily unavailable. Try again shortly."
        case .timeout: "The AI provider took too long to respond. Try again."
        case .incomplete: "The response ended before it was complete. Try again."
        case .invalidOutput: "Postmere couldn’t read the AI response. Try again."
        case .refused: "The AI provider declined this request."
        }
    }

    var canRetry: Bool {
        switch self {
        case .notConfigured, .credentials, .request, .refused: false
        default: true
        }
    }
}

nonisolated struct BackendHTTPClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    private let maximumBytes = 40 * 1024 * 1024

    init(baseURL: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        self.baseURL = try Self.validatedBaseURL(baseURL)
        let isolated = Self.isolatedConfiguration(configuration)
        isolated.timeoutIntervalForRequest = 45
        isolated.timeoutIntervalForResource = 190
        session = URLSession(configuration: isolated, delegate: BackendNoRedirect(), delegateQueue: nil)
    }

    static func isolatedConfiguration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.httpCookieAcceptPolicy = .never
        isolated.urlCache = nil
        isolated.urlCredentialStorage = nil
        isolated.httpAdditionalHeaders = [:]
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        return isolated
    }

    static func validatedBaseURL(_ baseURL: String) throws -> URL {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = components.url, let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw BackendError.invalidURL }
        let loopback = ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host.lowercased())
        guard components.scheme == "https" || (components.scheme == "http" && loopback) else { throw BackendError.insecureURL }
        return url
    }

    @concurrent func request<Response: Decodable & Sendable>(_ method: String, _ path: String, token: String? = nil,
                                                 query: [URLQueryItem] = [], as: Response.Type = Response.self) async throws -> Response {
        let data = try await raw(method, path, token: token, query: query)
        if data.isEmpty, let empty = BackendEmpty() as? Response { return empty }
        do { return try Self.decoder().decode(Response.self, from: data) }
        catch { throw BackendError.invalidResponse }
    }

    @concurrent func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ method: String, _ path: String,
                         token: String? = nil, body: Body, as: Response.Type = Response.self) async throws -> Response {
        let data = try await raw(method, path, token: token, body: Self.encoder().encode(body))
        if data.isEmpty, let empty = BackendEmpty() as? Response { return empty }
        do { return try Self.decoder().decode(Response.self, from: data) }
        catch { throw BackendError.invalidResponse }
    }

    @concurrent func raw(_ method: String, _ path: String, token: String? = nil, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard path.hasPrefix("/v1/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw BackendError.invalidURL }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        // URLComponents allows literal '+' in a query, while the server's form
        // parser treats it as a space. Preserve opaque cursors and email tags.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw BackendError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if method == "POST", Self.isAIRequest(path) {
            request.timeoutInterval = path.hasSuffix("/sender-profile") ? 180 : 115
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        guard !(300...399).contains(response.statusCode) else { throw BackendError.redirect }
        guard response.expectedContentLength <= maximumBytes else { throw BackendError.tooLarge }
        var data = Data()
        // Append to Data in blocks while still enforcing the limit on untrusted lengths.
        let blockSize = 16 * 1024
        var block: [UInt8] = []
        block.reserveCapacity(blockSize)
        for try await byte in bytes {
            guard data.count + block.count < maximumBytes else { throw BackendError.tooLarge }
            block.append(byte)
            if block.count == blockSize {
                data.append(contentsOf: block)
                block.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: block)
        guard (200...299).contains(response.statusCode) else {
            throw Self.responseError(status: response.statusCode, path: path, data: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
        return data
    }

    private static func isAIRequest(_ path: String) -> Bool {
        if path.hasPrefix("/v1/ai/") || path == "/v1/decisions/spam" || path == "/v1/decisions/triage" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count == 5 && parts[0] == "v1" && parts[1] == "mail" && parts[2] == "messages"
            && UUID(uuidString: String(parts[3])) != nil && parts[4] == "sender-profile"
    }

    static func responseError(status: Int, path: String, data: Data, retryAfter: String? = nil) -> any Error {
        if status == 429, ["/v1/events", "/v1/mail/accounts"].contains(path) || (path.hasPrefix("/v1/mail/accounts/") && path.hasSuffix("/sync")) {
            let now = Date.now
            var retryAt = now.addingTimeInterval(60)
            if let value = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if let seconds = UInt32(value) { retryAt = now.addingTimeInterval(TimeInterval(seconds)) }
                else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let date = formatter.date(from: value) { retryAt = date }
                }
            }
            return BackendError.mailSyncRateLimited(retryAt: max(now.addingTimeInterval(1), retryAt))
        }
        // Only client-owned messages may be shown. Provider bodies can contain private data.
        if Self.isAIRequest(path), ![401, 403].contains(status) {
            struct Envelope: Decodable {
                struct Detail: Decodable { let code: String }
                let error: Detail
            }
            if data.count <= 16 * 1024,
               let detail = try? JSONDecoder().decode(Envelope.self, from: data),
               let error = BackendAIError(rawValue: detail.error.code) { return error }
            switch status {
            case 408, 504: return BackendAIError.timeout
            case 502, 503: return BackendAIError.unavailable
            default: break
            }
        }
        let message: String
        switch status {
        case 401: message = "Your workspace sign-in is no longer valid, or the sign-in details were not accepted."
        case 403: message = "This account does not have access to that operation."
        case 404: message = "That item is no longer available."
        case 409: message = "The item changed. Refresh it before trying again."
        case 422, 400: message = "Check the information and try again."
        case 429: message = "Too many requests. Wait a moment and try again."
        case 503: message = "This service is not configured or is temporarily unavailable."
        default: message = "The server could not complete the request (\(status))."
        }
        return BackendError.response(status, message)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated final class BackendNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
