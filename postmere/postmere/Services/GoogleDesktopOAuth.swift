import Foundation
import AppKit
import CryptoKit
import Network
import Security

/// Google's Desktop OAuth flow: system browser, ephemeral loopback port, PKCE, and state.
/// https://developers.google.com/identity/protocols/oauth2/native-app
nonisolated enum GoogleDesktopOAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.modify"

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GmailError.authorization("Could not create a secure sign-in request. Please try again.")
        }
        return GmailEncoding.base64URL(Data(bytes))
    }

    static func authorizationURL(clientID: String, redirect: URL, state: String, verifier: String) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: GmailEncoding.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components.url else { throw GmailError.invalidResponse }
        return url
    }
}

actor GoogleOAuthLoopback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timeout: Task<Void, Never>?
    private var expectedState = ""
    private var redirectURL: URL?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "app.postmere.oauth-loopback")

    func start(state: String) async throws -> URL {
        expectedState = state
        let parameters = NWParameters.tcp
        // Do not listen on all interfaces: this callback is reachable only from this Mac.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) }
            catch { return }
            await self?.finish(.failure(GmailError.authorization("Google sign-in timed out. Please try again.")))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if case .failure(let error) = result { continuation.resume(throwing: error); return }
                ready = continuation
                listener.start(queue: queue)
            }
        } onCancel: { Task { await self.cancel() } }
    }

    func authorizationCode() async throws -> String {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback = $0 }
        } onCancel: { Task { await self.cancel() } }
    }

    func cancel() { finish(.failure(GmailError.cancelled)) }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                finish(.failure(GmailError.invalidResponse)); return
            }
            redirectURL = url
            ready?.resume(returning: url); ready = nil
        case .failed:
            finish(.failure(GmailError.authorization("Postmere could not open the local Google sign-in callback. Check that this build permits incoming network connections.")))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(10))
            guard let connection else { return }
            await self?.close(connection)
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - buffer.count) { [weak self] data, _, complete, error in
            Task { await self?.received(connection, buffer: buffer, data: data, complete: complete, failed: error != nil) }
        }
    }

    private func received(_ connection: NWConnection, buffer: Data, data: Data?, complete: Bool, failed: Bool) {
        var bytes = buffer
        if let data { bytes.append(data) }
        guard !failed, !bytes.isEmpty else { close(connection); return }
        guard bytes.count < 16_384 else { respond(connection, status: "431 Request Header Fields Too Large"); return }
        guard let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
            if complete { close(connection) } else { receive(connection, buffer: bytes) }
            return
        }
        let lines = request.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard let redirectURL, first.count == 3, first[0] == "GET", first[1].hasPrefix("/?"),
              let host = lines.first(where: { $0.lowercased().hasPrefix("host:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces),
              host == "127.0.0.1:\(redirectURL.port ?? 0)",
              let url = URL(string: String(first[1]), relativeTo: redirectURL)?.absoluteURL,
              url.host == "127.0.0.1", url.path == "/",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState else {
            respond(connection, status: "400 Bad Request"); return
        }
        let codes = items.filter { $0.name == "code" }
        let errors = items.filter { $0.name == "error" }
        if errors.count == 1, codes.isEmpty {
            respond(connection, status: "200 OK")
            finish(.failure(errors[0].value == "access_denied" ? GmailError.cancelled
                : GmailError.authorization("Google could not authorize Postmere. Check the OAuth app configuration and try again.")), preserving: connection)
        } else if codes.count == 1, errors.isEmpty, let code = codes[0].value, !code.isEmpty {
            respond(connection, status: "200 OK")
            finish(.success(code), preserving: connection)
        } else { respond(connection, status: "400 Bad Request") }
    }

    private func respond(_ connection: NWConnection, status: String) {
        let body = "<!doctype html><html><meta charset=\"utf-8\"><title>Postmere</title><body><h1>Return to Postmere</h1><p>You can close this browser tab. Postmere will show the result of your Google sign-in.</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(connection) }
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func finish(_ result: Result<String, Error>, preserving: NWConnection? = nil) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values where connection !== preserving { connection.cancel() }
        connections = preserving.map { [ObjectIdentifier($0): $0] } ?? [:]
        if let ready {
            switch result {
            case .failure(let error): ready.resume(throwing: error)
            case .success: ready.resume(throwing: GmailError.invalidResponse)
            }
            self.ready = nil
        }
        callback?.resume(with: result); callback = nil
    }
}
