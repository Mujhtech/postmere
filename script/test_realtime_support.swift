import Foundation

nonisolated final class RealtimeFixtureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    private var cancellations = 0
    func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    func cancelled() { lock.lock(); defer { lock.unlock() }; cancellations += 1 }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
}

nonisolated final class RealtimeFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, RealtimeFixtureProtocol) -> Void)!
    nonisolated(unsafe) static var recorder = RealtimeFixtureRecorder()
    private var activeRecorder: RealtimeFixtureRecorder?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { activeRecorder = Self.recorder; activeRecorder?.record(request); Self.handler(request, self) }
    override func stopLoading() { activeRecorder?.cancelled() }
    func response(_ status: Int, headers: [String: String] = [:], chunks: [Data] = [], finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
    static func configuration() -> URLSessionConfiguration {
        let result = URLSessionConfiguration.ephemeral
        result.protocolClasses = [Self.self]
        result.httpAdditionalHeaders = ["Cookie":"ambient", "Authorization":"ambient", "X-Ambient":"secret"]
        return result
    }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

nonisolated struct RealtimeFixtureFailure: Error { let message: String }

@MainActor
func realtimeCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw RealtimeFixtureFailure(message: message) }
}

@MainActor
func eventually(_ message: String, _ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw RealtimeFixtureFailure(message: message)
}
