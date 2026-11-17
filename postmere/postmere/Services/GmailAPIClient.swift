import Foundation

nonisolated final class GmailSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // OAuth credentials and authenticated message requests must never follow redirects.
        completionHandler(nil)
    }
}

/// REST and credential work stays off the UI actor. No third-party OAuth SDK is required.
actor GmailAPIClient {
    private let storage: any GmailCredentialStorage
    private let session: URLSession
    private var credentials: GmailCredentials?
    private var loaded = false
    private var generation = UUID()
    private var refreshTask: Task<GmailCredentials, Error>?

    init(storage: any GmailCredentialStorage = GmailKeychain(), session: URLSession? = nil) {
        self.storage = storage
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration, delegate: GmailSessionDelegate(), delegateQueue: nil)
        }
    }

    func connectionInfo() async throws -> GmailConnectionInfo? {
        try await loadIfNeeded()
        guard let credentials else { return nil }
        return .init(clientID: credentials.clientID, hasClientSecret: credentials.clientSecret?.isEmpty == false,
                     email: credentials.email, displayName: credentials.displayName,
                     hasTokens: credentials.refreshToken != nil || credentials.accessToken != nil)
    }

    func configure(clientID: String, clientSecret: String?, displayName: String?) async throws {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw GmailError.configuration("Enter a Google OAuth client ID for a Desktop app, ending in .apps.googleusercontent.com.")
        }
        try await loadIfNeeded()
        var updated = credentials?.clientID == clientID ? credentials! : GmailCredentials(clientID: clientID)
        if let clientSecret { updated.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        if let displayName { updated.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        refreshTask?.cancel(); refreshTask = nil
        generation = UUID()
        try await storage.save(updated)
        credentials = updated
    }

    func finishAuthorization(code: String, verifier: String, redirectURI: String) async throws -> GmailProfile {
        try await loadIfNeeded()
        guard var credentials else { throw GmailError.notConnected }
        let currentGeneration = generation
        var parameters = ["client_id": credentials.clientID, "code": code, "code_verifier": verifier,
                          "redirect_uri": redirectURI, "grant_type": "authorization_code"]
        if let secret = credentials.clientSecret { parameters["client_secret"] = secret }
        let token = try await Self.exchange(parameters: parameters, session: session)
        guard currentGeneration == generation else { throw GmailError.cancelled }
        guard token.scope?.split(separator: " ").contains(Substring(GoogleDesktopOAuth.scope)) != false else {
            throw GmailError.authorization("Google did not grant mail access. Sign in again and allow Postmere to read, send, and organize your Gmail.")
        }
        guard let refresh = token.refresh_token else {
            throw GmailError.authorization("Google did not return offline access. Remove Postmere from your Google account permissions and reconnect.")
        }
        credentials.accessToken = token.access_token
        credentials.refreshToken = refresh
        credentials.expiresAt = Date().addingTimeInterval(token.expires_in)
        credentials.scope = token.scope
        // A fresh sign-in may select another account. Never carry over its old profile.
        credentials.email = nil
        try await storage.save(credentials)
        self.credentials = credentials
        return try await profile()
    }

    func profile() async throws -> GmailProfile {
        let profile: GmailProfile = try await request(path: "profile")
        guard var updated = credentials else { throw GmailError.notConnected }
        if updated.email == profile.emailAddress { return profile }
        updated.email = profile.emailAddress
        try await storage.save(updated)
        credentials = updated
        return profile
    }

    /// Returns an explicit bounded snapshot; the facade exposes hasMoreMessages to the UI.
    func sync(maximumMessages: Int) async throws -> GmailSyncResult {
        let limit = max(1, maximumMessages)
        var references: [GmailMessageReference] = []
        var pageToken: String?
        repeat {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "maxResults", value: String(min(500, limit - references.count))),
                         .init(name: "includeSpamTrash", value: "true"), .init(name: "q", value: "-in:spam")]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let page: GmailMessageList = try await request(path: "messages", query: query)
            references += page.messages ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil && references.count < limit

        var messages: [GmailWireMessage] = []
        // Bound concurrent requests to avoid a burst of hundreds of per-message calls.
        for batchStart in stride(from: 0, to: references.count, by: 6) {
            let batch = Array(references[batchStart..<min(batchStart + 6, references.count)])
            let fetched = try await withThrowingTaskGroup(of: GmailWireMessage?.self) { group in
                for reference in batch {
                    group.addTask {
                        do { return try await self.message(id: reference.id) }
                        catch GmailError.http(404, _) { return nil } // Deleted since messages.list.
                    }
                }
                var result: [GmailWireMessage] = []
                for try await message in group { if let message { result.append(message) } }
                return result
            }
            messages += fetched
            try Task.checkCancellation()
        }
        messages.sort { (Int64($0.internalDate ?? "") ?? 0) > (Int64($1.internalDate ?? "") ?? 0) }
        return .init(messages: messages, hasMore: pageToken != nil)
    }

    func message(id: String, expectedAccountEmail: String? = nil) async throws -> GmailWireMessage {
        var message: GmailWireMessage = try await request(path: "messages/\(try safeID(id))", query: [.init(name: "format", value: "full")], expectedAccountEmail: expectedAccountEmail)
        if let payload = message.payload { message.payload = try await hydrateTextParts(payload, messageID: id, expectedAccountEmail: expectedAccountEmail) }
        return message
    }

    /// Absence from a bounded list is not deletion. Only an explicit 404 is unavailable.
    func verify(messageIDs: [String], expectedAccountEmail: String) async throws -> GmailVerificationResult {
        var result = GmailVerificationResult(messages: [], unavailableMessageIDs: [])
        for id in Set(messageIDs).sorted().prefix(12) {
            try Task.checkCancellation()
            do { result.messages.append(try await message(id: id, expectedAccountEmail: expectedAccountEmail)) }
            catch GmailError.http(404, _) { result.unavailableMessageIDs.insert(id) }
        }
        return result
    }

    func attachmentData(messageID: String, attachmentID: String, expectedAccountEmail: String? = nil) async throws -> Data {
        let body: GmailPartBody = try await request(path: "messages/\(try safeID(messageID))/attachments/\(try safeID(attachmentID))", expectedAccountEmail: expectedAccountEmail)
        guard let encoded = body.data, let data = GmailEncoding.decodeBase64URL(encoded) else { throw GmailError.invalidResponse }
        return data
    }

    func send(raw: Data, threadID: String?, expectedAccountEmail: String? = nil) async throws -> GmailWireMessage {
        // Never retry an ambiguous transport/5xx send failure: Gmail has no idempotency key here.
        let body = try JSONEncoder().encode(GmailSendRequest(raw: GmailEncoding.base64URL(raw), threadId: threadID))
        return try await request(path: "messages/send", method: "POST", body: body, isSend: true, expectedAccountEmail: expectedAccountEmail)
    }

    func modifyLabels(messageID: String, add: [String], remove: [String], expectedAccountEmail: String? = nil) async throws {
        let body = try JSONEncoder().encode(GmailModifyRequest(addLabelIds: add, removeLabelIds: remove))
        let _: GmailWireMessage = try await request(path: "messages/\(try safeID(messageID))/modify", method: "POST", body: body, expectedAccountEmail: expectedAccountEmail)
    }

    func trash(messageID: String, restore: Bool = false, expectedAccountEmail: String? = nil) async throws {
        let _: GmailWireMessage = try await request(path: "messages/\(try safeID(messageID))/\(restore ? "untrash" : "trash")", method: "POST", body: Data("{}".utf8), expectedAccountEmail: expectedAccountEmail)
    }

    /// Clear local tokens even when Google's revocation endpoint is unavailable.
    func disconnect() async throws -> String? {
        try await loadIfNeeded()
        generation = UUID()
        refreshTask?.cancel(); refreshTask = nil
        let old = credentials
        credentials = nil
        loaded = true
        try await storage.delete()
        if let clientID = old?.clientID {
            let publicConfiguration = GmailCredentials(clientID: clientID)
            try await storage.save(publicConfiguration)
            credentials = publicConfiguration
        }
        guard let token = old?.refreshToken ?? old?.accessToken else { return nil }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GmailEncoding.form(["token": token])
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw GmailError.invalidResponse }
            return nil
        } catch {
            return "Disconnected from this Mac. Google’s access could not be revoked; you can remove it from your Google Account permissions."
        }
    }

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        credentials = try await storage.load()
        loaded = true
    }

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        try await loadIfNeeded()
        guard let credentials else { throw GmailError.notConnected }
        if !forceRefresh, let token = credentials.accessToken,
           (credentials.expiresAt ?? .distantPast) > Date().addingTimeInterval(60) { return token }
        if let refreshTask { return try await refreshTask.value.accessToken ?? "" }
        guard let refresh = credentials.refreshToken else { throw GmailError.notConnected }
        let currentGeneration = generation
        let session = session
        let task = Task<GmailCredentials, Error> {
            var parameters = ["client_id": credentials.clientID, "grant_type": "refresh_token", "refresh_token": refresh]
            if let secret = credentials.clientSecret { parameters["client_secret"] = secret }
            let response = try await Self.exchange(parameters: parameters, session: session)
            var updated = credentials
            updated.accessToken = response.access_token
            updated.refreshToken = response.refresh_token ?? refresh
            updated.expiresAt = Date().addingTimeInterval(response.expires_in)
            updated.scope = response.scope ?? credentials.scope
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let updated = try await task.value
            guard currentGeneration == generation else { throw GmailError.cancelled }
            self.credentials = updated
            try await storage.save(updated)
            return updated.accessToken ?? ""
        } catch {
            if case GmailError.notConnected = error, currentGeneration == generation {
                var cleared = credentials
                cleared.accessToken = nil; cleared.refreshToken = nil; cleared.expiresAt = nil
                try await storage.save(cleared)
                self.credentials = cleared
            }
            throw error
        }
    }

    private func request<T: Decodable & Sendable>(path: String, query: [URLQueryItem] = [], method: String = "GET",
                                                 body: Data? = nil, isSend: Bool = false, expectedAccountEmail: String? = nil) async throws -> T {
        let requestGeneration = generation
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw GmailError.invalidResponse }
        var refreshed = false
        var refreshNextRequest = false
        var retries = 0
        while true {
            try Task.checkCancellation()
            let token = try await accessToken(forceRefresh: refreshNextRequest)
            refreshNextRequest = false
            guard requestGeneration == generation else { throw GmailError.cancelled }
            if let expectedAccountEmail, credentials?.email?.caseInsensitiveCompare(expectedAccountEmail) != .orderedSame {
                throw GmailError.invalidMessage("This email belongs to another Gmail account. Reconnect that account before continuing.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let data: Data; let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch { if isSend { throw GmailError.sendUnconfirmed }; throw error }
            guard requestGeneration == generation else { throw GmailError.cancelled }
            guard let http = response as? HTTPURLResponse else { throw GmailError.invalidResponse }
            if http.statusCode == 401, !refreshed { refreshed = true; refreshNextRequest = true; continue }
            if method == "GET", [429, 500, 502, 503, 504].contains(http.statusCode), retries < 2 {
                let delay = min(30, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(retries))))
                retries += 1
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                if isSend, http.statusCode >= 500 { throw GmailError.sendUnconfirmed }
                throw GmailError.http(http.statusCode, Self.apiErrorMessage(data))
            }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { if isSend { throw GmailError.sendUnconfirmed }; throw GmailError.invalidResponse }
        }
    }

    private func hydrateTextParts(_ part: GmailMessagePart, messageID: String, expectedAccountEmail: String?) async throws -> GmailMessagePart {
        guard !part.isAttachment else { return part }
        var part = part
        if (part.filename ?? "").isEmpty, part.mimeType?.hasPrefix("text/") == true,
           part.body?.data == nil, let attachmentID = part.body?.attachmentId {
            let data = try await attachmentData(messageID: messageID, attachmentID: attachmentID, expectedAccountEmail: expectedAccountEmail)
            part.body?.data = GmailEncoding.base64URL(data)
        }
        if let parts = part.parts {
            var hydrated: [GmailMessagePart] = []
            for child in parts { hydrated.append(try await hydrateTextParts(child, messageID: messageID, expectedAccountEmail: expectedAccountEmail)) }
            part.parts = hydrated
        }
        return part
    }

    private func safeID(_ id: String) throws -> String {
        guard !id.isEmpty, id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw GmailError.invalidResponse }
        return id
    }

    private static func exchange(parameters: [String: String], session: URLSession) async throws -> GmailTokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.httpBody = GmailEncoding.form(parameters)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch object?["error"] as? String {
            case "invalid_grant": throw GmailError.notConnected
            case "invalid_client", "unauthorized_client":
                throw GmailError.configuration("Google rejected this OAuth client. Use a Desktop app client ID and, if required by your project, its client secret.")
            default: throw GmailError.authorization("Google could not complete sign-in (\(http.statusCode)). Check the OAuth app’s test users and Gmail API access.")
            }
        }
        let token = try JSONDecoder().decode(GmailTokenResponse.self, from: data)
        guard !token.access_token.isEmpty, token.expires_in > 0,
              token.token_type?.lowercased() != "dpop" else { throw GmailError.invalidResponse }
        return token
    }

    private static func apiErrorMessage(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let detail = (object?["error"] as? [String: Any])?["message"] as? String
        return String((detail ?? "The request could not be completed.").prefix(350))
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
