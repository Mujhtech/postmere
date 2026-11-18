import Foundation

@MainActor
final class EventFixtureState {
    var events: [BackendServerEvent] = []
    var cursors: [String?] = []
    var receivers: [@MainActor @Sendable (BackendServerEvent) throws -> Void] = []
    var refreshes: [BackendEventChanges] = []
    var refreshBlocked = false
    var releaseRefresh = false
}

@main
struct BackendEventFixtures {
    static let ready = BackendServerEvent(name: "ready", id: "opaque-1", data: "{\"version\":1,\"kinds\":[\"mail\",\"accounts\",\"outbox\"]}")
    static func change(_ kind: String, id: String = "opaque-2") -> BackendServerEvent {
        BackendServerEvent(name: "change", id: id, data: "{\"version\":1,\"kinds\":[\"\(kind)\"]}")
    }

    static func main() async throws {
        try parserFixtures()
        try await transportFixtures()
        try await coordinatorFixtures()
        print("PASS: bounded SSE parsing, authenticated transport, MIME/redirect/error checks and prompt cancellation")
        print("PASS: reconnect cursor, bounded backoff, burst coalescing, in-flight refresh follow-up and login-generation isolation")
        print("PASS: all network traffic intercepted; no app restart, server, mailbox or APNs contacted")
    }

    static func parserFixtures() throws {
        var parser = BackendEventParser()
        let wire = "\u{feff}: heartbeat\r\nid: cursor-1\revent: change\rdata: {\"version\":1,\rdata: \"kinds\":[\"mail\"]}\r\r: beat\n\nevent: future\nid:\ndata: hello café\n\n"
        var events: [BackendServerEvent] = []
        for byte in wire.utf8 { if let event = try parser.append(byte) { events.append(event) } }
        try realtimeCheck(events.count == 2 && events[0].id == "cursor-1", "SSE CR/LF/CRLF or comment/BOM handling failed")
        try realtimeCheck(try events[0].changes == .mail, "SSE multiline payload did not decode")
        try realtimeCheck(events[1].data == "hello café" && events[1].id == "" && (try events[1].changes).isEmpty, "UTF-8/unknown-event/empty-ID behavior changed")
        try realtimeCheck(try ready.changes == .all, "Ready must reconcile every durable cache")
        var partial = BackendEventParser()
        for byte in "event: change\ndata: {\"version\":1}".utf8 {
            try realtimeCheck(try partial.append(byte) == nil, "Incomplete event was dispatched")
        }
        for wire in [String(repeating: "x", count: BackendEventParser.maximumLineBytes + 1),
                     "id: " + String(repeating: "a", count: 257) + "\n",
                     String(repeating: "data: x\n", count: 5000)] {
            var limited = BackendEventParser()
            do { for byte in wire.utf8 { _ = try limited.append(byte) }; throw RealtimeFixtureFailure(message: "Unbounded SSE input accepted") }
            catch is BackendError {}
        }
        var invalidUTF8 = BackendEventParser()
        _ = try invalidUTF8.append(255)
        do { _ = try invalidUTF8.append(10); throw RealtimeFixtureFailure(message: "Invalid UTF-8 accepted") } catch is BackendError {}
        do { _ = try BackendServerEvent(name: "change", id: nil, data: "{\"version\":2,\"kinds\":[]}").changes; throw RealtimeFixtureFailure(message: "Unknown event version accepted") } catch is BackendError {}
        var backoff = BackendEventBackoff()
        let delays = (0..<10).map { _ in backoff.nextDelay(stableConnection: false, jitter: 0.5) }
        try realtimeCheck(delays == [1,2,4,8,16,32,60,60,60,60], "Reconnect delay does not back off to a bounded rate")
        try realtimeCheck(backoff.nextDelay(stableConnection: true, jitter: 0.5) == 1, "Healthy stream did not reset backoff")
    }

    static func transportFixtures() async throws {
        RealtimeFixtureProtocol.recorder = RealtimeFixtureRecorder()
        RealtimeFixtureProtocol.handler = { _, fixture in
            let chunks = "id: cursor-2\nevent: change\ndata: {\"version\":1,\"kinds\":[\"mail\"]}\n\n".utf8.map { Data([$0]) }
            fixture.response(200, headers: ["Content-Type":"text/event-stream; charset=utf-8"], chunks: chunks)
        }
        let state = EventFixtureState()
        let stream = try BackendEventStream(baseURL: "https://postmere.example.test/", configuration: RealtimeFixtureProtocol.configuration())
        try await stream.consume(token: "fixture-token", lastEventID: "cursor-1") { event in await MainActor.run { state.events.append(event) } }
        let request = RealtimeFixtureProtocol.recorder.requests[0]
        try realtimeCheck(request.url?.absoluteString == "https://postmere.example.test/v1/events", "Stream escaped the configured origin")
        try realtimeCheck(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" && request.value(forHTTPHeaderField: "Last-Event-ID") == "cursor-1", "Stream lost explicit credentials or resume cursor")
        try realtimeCheck(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "X-Ambient") == nil, "Ambient credentials leaked into stream")
        try realtimeCheck(state.events.count == 1 && state.events[0].id == "cursor-2", "Split stream bytes were not delivered")
        do { try await stream.consume(token: "fixture", lastEventID: "bad\r\nAuthorization: injected") { _ in }; throw RealtimeFixtureFailure(message: "Header-injection cursor accepted") } catch is BackendError {}
        try realtimeCheck(RealtimeFixtureProtocol.recorder.requests.count == 1, "Unsafe cursor issued a request")
        for (status, mime) in [(200,"application/json"),(302,"text/event-stream"),(401,"text/event-stream")] {
            RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(status, headers: ["Content-Type":mime,"Location":"https://attacker.example.test/"], chunks: [Data("secret-response".utf8)]) }
            do { try await stream.consume(token: "fixture", lastEventID: nil) { _ in }; throw RealtimeFixtureFailure(message: "Invalid stream response accepted") }
            catch let error as BackendError { try realtimeCheck(!error.localizedDescription.contains("secret-response"), "Server body leaked through error") }
        }
        let recorder = RealtimeFixtureRecorder()
        RealtimeFixtureProtocol.recorder = recorder
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(200, headers: ["Content-Type":"text/event-stream"], chunks: [Data(": heartbeat\n\n".utf8)], finish: false) }
        let task = Task { try await stream.consume(token: "fixture", lastEventID: nil) { _ in } }
        try await eventually("Stream did not begin", { recorder.requests.count == 1 })
        task.cancel()
        _ = try? await task.value
        try await eventually("Cancellation did not stop the HTTP task", { recorder.stopCount > 0 })
    }

    static func coordinatorFixtures() async throws {
        let state = EventFixtureState()
        let coordinator = BackendRealtimeCoordinator(debounce: 0.01, sleep: { seconds in
            try await Task.sleep(for: .milliseconds(seconds < 1 ? 10 : 1))
        }, jitter: { 0.5 })
        let firstGeneration = UUID()
        let connect: BackendRealtimeCoordinator.Connection = { cursor, receive in
            state.cursors.append(cursor)
            state.receivers.append(receive)
            if state.cursors.count == 1 {
                try receive(ready)
                throw URLError(.networkConnectionLost)
            }
            try await Task.sleep(for: .seconds(3600))
        }
        let refresh: BackendRealtimeCoordinator.Refresh = { changes in
            state.refreshes.append(changes)
            if state.refreshBlocked {
                while !state.releaseRefresh && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        coordinator.update(generation: firstGeneration, connect: connect, refresh: refresh)
        try await eventually("Dropped stream did not reconnect", { state.cursors.count == 2 })
        try realtimeCheck(state.cursors[0] == nil && state.cursors[1] == "opaque-1", "Reconnect did not preserve its scoped cursor")
        try await eventually("Ready did not refresh cache", { state.refreshes.count == 1 })
        try state.receivers[1](change("mail"))
        try state.receivers[1](change("outbox"))
        try state.receivers[1](change("accounts"))
        try await eventually("Burst did not refresh", { state.refreshes.count == 2 })
        try realtimeCheck(state.refreshes[1] == .all, "Burst events were not coalesced")
        state.refreshBlocked = true
        try state.receivers[1](change("mail"))
        try await eventually("Refresh did not begin", { state.refreshes.count == 3 })
        try state.receivers[1](change("outbox"))
        state.releaseRefresh = true
        try await eventually("Change during refresh was dropped", { state.refreshes.count == 4 })
        let stale = state.receivers[1]
        coordinator.update(generation: nil, connect: connect, refresh: refresh)
        do { try stale(change("mail")); throw RealtimeFixtureFailure(message: "Signed-out event was accepted") } catch is CancellationError {}
        let prior = state.refreshes.count
        coordinator.update(generation: UUID(), connect: connect, refresh: refresh)
        try await eventually("New login did not open stream", { state.cursors.count == 3 })
        try realtimeCheck(state.cursors[2] == nil, "New login reused the previous session cursor")
        do { try stale(change("mail")); throw RealtimeFixtureFailure(message: "Same-workspace previous-login event was accepted") } catch is CancellationError {}
        try realtimeCheck(state.refreshes.count == prior, "Stale callback scheduled a cache refresh")
        coordinator.update(generation: nil, connect: connect, refresh: refresh)
    }
}
