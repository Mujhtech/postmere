import Foundation

nonisolated struct BackendEventChanges: OptionSet, Sendable {
    let rawValue: Int
    static let mail = Self(rawValue: 1 << 0)
    static let accounts = Self(rawValue: 1 << 1)
    static let outbox = Self(rawValue: 1 << 2)
    static let all: Self = [.mail, .accounts, .outbox]
}

nonisolated struct BackendServerEvent: Sendable, Equatable {
    let name: String
    let id: String?
    let data: String

    var changes: BackendEventChanges {
        get throws {
            guard ["ready", "reset", "change"].contains(name) else { return [] }
            struct Payload: Decodable { let version: Int; let kinds: [String] }
            guard let bytes = data.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(Payload.self, from: bytes),
                  payload.version == 1, payload.kinds.count <= 8 else { throw BackendError.invalidResponse }
            // Every connection reconciles the durable account/cache cursors;
            // Last-Event-ID is a hint, never proof that no changes were missed.
            if name == "ready" || name == "reset" { return .all }
            return payload.kinds.reduce(into: BackendEventChanges()) { result, kind in
                switch kind {
                case "mail": result.insert(.mail)
                case "accounts": result.insert(.accounts)
                case "outbox": result.insert(.outbox)
                default: break
                }
            }
        }
    }
}

/// Byte-wise parsing bounds a malicious/incorrect server before allocating an
/// unbounded line. A complete blank-line-delimited event is required to act.
nonisolated struct BackendEventParser {
    static let maximumLineBytes = 8 * 1024
    static let maximumEventBytes = 32 * 1024
    private var line = Data()
    private var eventBytes = 0
    private var eventName = "message"
    private var eventID: String?
    private var dataLines: [String] = []
    private var wasCR = false
    private var firstLine = true

    mutating func append(_ byte: UInt8) throws -> BackendServerEvent? {
        if wasCR {
            wasCR = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            wasCR = byte == 13
            return try finishLine()
        }
        guard line.count < Self.maximumLineBytes, eventBytes < Self.maximumEventBytes else { throw BackendError.tooLarge }
        line.append(byte)
        eventBytes += 1
        return nil
    }

    private mutating func finishLine() throws -> BackendServerEvent? {
        guard var value = String(data: line, encoding: .utf8) else { throw BackendError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if value.first == "\u{feff}" { value.removeFirst() }
        }
        if value.isEmpty {
            let event = dataLines.isEmpty ? nil : BackendServerEvent(name: eventName, id: eventID, data: dataLines.joined(separator: "\n"))
            eventName = "message"
            eventID = nil
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            return event
        }
        // Heartbeats do not contribute to the unfinished event budget.
        if value.hasPrefix(":") {
            eventBytes -= value.utf8.count
            return nil
        }
        let pieces = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pieces[0])
        var content = pieces.count == 2 ? String(pieces[1]) : ""
        if content.hasPrefix(" ") { content.removeFirst() }
        switch field {
        case "event":
            guard content.utf8.count <= 64 else { throw BackendError.tooLarge }
            eventName = content
        case "id":
            guard content.isEmpty || Self.validCursor(content) else { throw BackendError.invalidResponse }
            eventID = content
        case "data": dataLines.append(content)
        default: break // SSE extension fields, including retry, are advisory.
        }
        return nil
    }

    static func validCursor(_ cursor: String) -> Bool {
        !cursor.isEmpty && cursor.utf8.count <= 256 && cursor.utf8.allSatisfy { (33...126).contains($0) }
    }
}

nonisolated struct BackendEventStream: Sendable {
    let baseURL: URL
    private let configuration: URLSessionConfiguration

    init(baseURL: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        self.baseURL = try BackendHTTPClient.validatedBaseURL(baseURL)
        self.configuration = BackendHTTPClient.isolatedConfiguration(configuration)
        self.configuration.timeoutIntervalForRequest = 45
        self.configuration.timeoutIntervalForResource = 60 * 60
    }

    func consume(token: String, lastEventID: String?,
                 receive: @escaping @Sendable (BackendServerEvent) async throws -> Void) async throws {
        guard !token.isEmpty else { throw BackendError.notConnected }
        if let lastEventID, !BackendEventParser.validCursor(lastEventID) { throw BackendError.invalidResponse }
        let url = baseURL.appendingPathComponent("v1/events")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let session = URLSession(configuration: configuration, delegate: BackendNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
            guard !(300...399).contains(response.statusCode) else { throw BackendError.redirect }
            guard response.statusCode == 200 else {
                throw BackendError.response(response.statusCode, response.statusCode == 401
                    ? "Your workspace session ended. Sign in again to continue."
                    : "Live updates are temporarily unavailable.")
            }
            guard response.url == url, response.mimeType?.lowercased() == "text/event-stream" else { throw BackendError.invalidResponse }
            var parser = BackendEventParser()
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try parser.append(byte) { try await receive(event) }
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

nonisolated struct BackendEventBackoff {
    private var failures = 0
    mutating func nextDelay(stableConnection: Bool, jitter: Double) -> TimeInterval {
        if stableConnection { failures = 0 }
        let delay = min(60, pow(2, Double(min(failures, 6))))
        failures = min(failures + 1, 6)
        return delay * (0.8 + 0.4 * min(1, max(0, jitter)))
    }
}

/// Owns one stream per verified login generation. Events are invalidation hints
/// and are coalesced into the existing persistence/notification reconciliation.
@MainActor
final class BackendRealtimeCoordinator {
    typealias Connection = @MainActor @Sendable (String?, @escaping @MainActor @Sendable (BackendServerEvent) throws -> Void) async throws -> Void
    typealias Refresh = @MainActor @Sendable (BackendEventChanges) async -> Void
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    private let sleep: Sleep
    private let jitter: @Sendable () -> Double
    private let debounce: TimeInterval
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation: UUID?
    private var lastEventID: String?
    private var pending: BackendEventChanges = []

    init(debounce: TimeInterval = 0.25,
         sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
         jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.debounce = debounce
        self.sleep = sleep
        self.jitter = jitter
    }

    deinit { connectionTask?.cancel(); refreshTask?.cancel() }

    func update(generation newGeneration: UUID?, connect: @escaping Connection, refresh: @escaping Refresh) {
        guard generation != newGeneration else { return }
        connectionTask?.cancel()
        refreshTask?.cancel()
        connectionTask = nil
        refreshTask = nil
        generation = newGeneration
        lastEventID = nil
        pending = []
        guard let newGeneration else { return }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            var backoff = BackendEventBackoff()
            while !Task.isCancelled, self.generation == newGeneration {
                let started = ContinuousClock.now
                var unavailable = false
                do {
                    try await connect(self.lastEventID) { [weak self] event in
                        guard let self, self.generation == newGeneration, !Task.isCancelled else { throw CancellationError() }
                        let changes = try event.changes
                        if let id = event.id { self.lastEventID = id.isEmpty ? nil : id }
                        self.enqueue(changes, generation: newGeneration, refresh: refresh)
                    }
                } catch is CancellationError { break }
                catch BackendError.notConnected { break }
                catch BackendError.response(401, _) { break }
                catch BackendError.response(let code, _) { unavailable = (400...499).contains(code) && code != 429 }
                catch { /* The existing poller keeps mail usable while offline. */ }
                guard !Task.isCancelled, self.generation == newGeneration else { break }
                let delay = backoff.nextDelay(stableConnection: started.duration(to: .now) >= .seconds(30), jitter: self.jitter())
                do { try await self.sleep(unavailable ? 300 : delay) }
                catch { break }
            }
        }
    }

    private func enqueue(_ changes: BackendEventChanges, generation requestGeneration: UUID, refresh: @escaping Refresh) {
        guard !changes.isEmpty else { return }
        pending.formUnion(changes)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == requestGeneration { self.refreshTask = nil } }
            while !Task.isCancelled, self.generation == requestGeneration, !self.pending.isEmpty {
                do { try await self.sleep(self.debounce) } catch { return }
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                let changes = self.pending
                self.pending = []
                await refresh(changes)
            }
        }
    }
}
