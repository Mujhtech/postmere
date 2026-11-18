import Foundation

nonisolated enum BackendError: LocalizedError, Sendable {
    case invalidURL, insecureURL, redirect, invalidResponse, tooLarge, notConnected
    case response(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter the server’s base URL without a query, fragment, or password."
        case .insecureURL: "Use HTTPS for your Postmere server. Local development can use loopback HTTP."
        case .redirect: "The server redirected this request. Check your workspace server address."
        case .invalidResponse: "The server returned an unreadable response."
        case .tooLarge: "The server response exceeded the size limit."
        case .notConnected: "Sign in to your Postmere workspace to continue."
        case let .response(_, message): message
        }
    }
}

nonisolated struct BackendEmpty: Codable, Sendable {}

nonisolated struct BackendHTTPClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    private let maximumBytes = 40 * 1024 * 1024

    init(baseURL: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        self.baseURL = try Self.validatedBaseURL(baseURL)
        let isolated = Self.isolatedConfiguration(configuration)
        isolated.timeoutIntervalForRequest = 45
        isolated.timeoutIntervalForResource = 120
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

    func request<Response: Decodable & Sendable>(_ method: String, _ path: String, token: String? = nil,
                                                 query: [URLQueryItem] = [], as: Response.Type = Response.self) async throws -> Response {
        let data = try await raw(method, path, token: token, query: query)
        if data.isEmpty, let empty = BackendEmpty() as? Response { return empty }
        do { return try Self.decoder().decode(Response.self, from: data) }
        catch { throw BackendError.invalidResponse }
    }

    func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ method: String, _ path: String,
                         token: String? = nil, body: Body, as: Response.Type = Response.self) async throws -> Response {
        let data = try await raw(method, path, token: token, body: Self.encoder().encode(body))
        if data.isEmpty, let empty = BackendEmpty() as? Response { return empty }
        do { return try Self.decoder().decode(Response.self, from: data) }
        catch { throw BackendError.invalidResponse }
    }

    func raw(_ method: String, _ path: String, token: String? = nil, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        guard !(300...399).contains(response.statusCode) else { throw BackendError.redirect }
        guard response.expectedContentLength <= maximumBytes else { throw BackendError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw BackendError.tooLarge }
            data.append(byte)
        }
        guard (200...299).contains(response.statusCode) else {
            // Do not expose arbitrary response HTML or provider credentials in UI errors.
            let message: String
            switch response.statusCode {
            case 401: message = "Your workspace sign-in is no longer valid, or the sign-in details were not accepted."
            case 403: message = "This account does not have access to that operation."
            case 404: message = "That item is no longer available."
            case 409: message = "The item changed. Refresh it before trying again."
            case 422, 400: message = "Check the information and try again."
            case 429: message = "Too many requests. Wait a moment and try again."
            case 503: message = "This service is not configured or is temporarily unavailable."
            default: message = "The server could not complete the request (\(response.statusCode))."
            }
            throw BackendError.response(response.statusCode, message)
        }
        return data
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: value.codingPath, debugDescription: "Invalid timestamp"))
            }
            return date
        }
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
