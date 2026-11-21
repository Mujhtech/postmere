import Foundation

/// Streams `POST /v1/ai/summary`, `/v1/ai/suggestions` or `/v1/ai/ask`: the
/// retrieved sources (questions only), prose deltas, each validated suggestion,
/// then the full result.
nonisolated struct BackendSummaryStream: Sendable {
    let baseURL: URL
    let configuration: URLSessionConfiguration

    private enum Event: Decodable {
        case sources([MailAISource]), delta(String), item(MailAIItem), done(MailAIResult), error(String)

        private enum Keys: CodingKey { case type, text, item, sources, result, code }
        init(from decoder: Decoder) throws {
            let payload = try decoder.container(keyedBy: Keys.self)
            switch try payload.decode(String.self, forKey: .type) {
            case "delta": self = .delta(try payload.decode(String.self, forKey: .text))
            case "sources": self = .sources(try payload.decode([MailAISource].self, forKey: .sources))
            case "item": self = .item(try payload.decode(MailAIItem.self, forKey: .item))
            case "done": self = .done(try payload.decode(MailAIResult.self, forKey: .result))
            case "error": self = .error(try payload.decode(String.self, forKey: .code))
            default: throw BackendAIError.invalidOutput
            }
        }
    }

    @concurrent func generate(path: String = "/v1/ai/summary", messageIDs: [UUID], token: String,
                              onDelta: @MainActor @Sendable (String) throws -> Void,
                              onItem: (@MainActor @Sendable (MailAIItem) throws -> Void)? = nil) async throws -> MailAIResult {
        try await generate(path: path, body: MailAISourceInput(messageIds: messageIDs), token: token,
                           onDelta: onDelta, onItem: onItem)
    }

    @concurrent func generate<Body: Encodable & Sendable>(
        path: String, body: Body, token: String,
        onSources: (@MainActor @Sendable ([MailAISource]) throws -> Void)? = nil,
        onDelta: @MainActor @Sendable (String) throws -> Void,
        onItem: (@MainActor @Sendable (MailAIItem) throws -> Void)? = nil
    ) async throws -> MailAIResult {
        let url = baseURL.appending(path: String(path.drop(while: { $0 == "/" })))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try BackendHTTPClient.encoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let isolated = BackendHTTPClient.isolatedConfiguration(configuration)
        isolated.timeoutIntervalForRequest = 115
        isolated.timeoutIntervalForResource = 195
        let session = URLSession(configuration: isolated, delegate: BackendNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
            guard !(300...399).contains(http.statusCode) else { throw BackendError.redirect }
            guard http.url == url else { throw BackendError.invalidResponse }
            guard http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes.prefix(16 * 1024) { body.append(byte) }
                throw BackendHTTPClient.responseError(status: http.statusCode, path: path, data: body)
            }
            let decoder = BackendHTTPClient.decoder()
            let limit = 2 * 1024 * 1024
            switch http.mimeType?.lowercased() {
            case "application/json":
                // Earlier servers return the complete result on the original request.
                guard http.expectedContentLength <= limit else { throw BackendError.tooLarge }
                var body = Data()
                for try await byte in bytes {
                    guard body.count < limit else { throw BackendError.tooLarge }
                    body.append(byte)
                }
                guard let result = try? decoder.decode(MailAIResult.self, from: body) else {
                    throw BackendAIError.invalidOutput
                }
                return result
            case "text/event-stream":
                var parser = BackendEventParser(lineLimit: limit, eventLimit: limit)
                var textBytes = 0
                var items = 0
                for try await byte in bytes {
                    guard let frame = try parser.append(byte) else { continue }
                    try Task.checkCancellation()
                    guard let event = try? decoder.decode(Event.self, from: Data(frame.data.utf8)) else {
                        throw BackendAIError.invalidOutput
                    }
                    switch event {
                    case .sources(let sources):
                        guard sources.count <= 50 else { throw BackendAIError.invalidOutput }
                        try await onSources?(sources)
                    case .delta(let text):
                        textBytes += text.utf8.count
                        guard textBytes <= 32_000 else { throw BackendError.tooLarge }
                        if !text.isEmpty { try await onDelta(text) }
                    case .item(let item):
                        items += 1
                        guard items <= 20 else { throw BackendAIError.invalidOutput }
                        try await onItem?(item)
                    case .done(let result): return result
                    case .error(let code): throw BackendAIError(rawValue: code) ?? .unavailable
                    }
                }
                throw BackendAIError.incomplete
            default: throw BackendAIError.invalidOutput
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}
