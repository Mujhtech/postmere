import Foundation
import Darwin

nonisolated struct MailUnsubscribeEmail: Equatable, Sendable {
    let recipients: [String]
    let subject: String
    let body: String
}

nonisolated enum MailUnsubscribeMethod: Equatable, Sendable {
    case email(MailUnsubscribeEmail)
    case web(URL)
}

nonisolated struct MailUnsubscribeOptions: Sendable {
    let oneClickURL: URL?
    /// RFC 2369 preference order, after removing unsupported or unsafe targets.
    let methods: [MailUnsubscribeMethod]
    let explanation: String?

    var isAvailable: Bool { oneClickURL != nil || !methods.isEmpty }
}

nonisolated enum MailUnsubscribeError: LocalizedError, Equatable {
    case unsupported
    case unsafeDestination
    case unresolvedHost
    case redirect
    case http(Int)
    case invalidResponse
    case browserUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: "This message does not have a verified one-click unsubscribe command. Use its email or browser option instead."
        case .unsafeDestination: "The unsubscribe address is not a supported public destination. No request was sent."
        case .unresolvedHost: "The unsubscribe website could not be found. Check your connection and try again."
        case .redirect: "The sender redirected the unsubscribe request. Postmere did not follow it. You can use the browser option instead."
        case .http(let status): "The sender’s server returned HTTP \(status). It did not confirm the unsubscribe request."
        case .invalidResponse: "The sender did not return a valid response. The unsubscribe request could not be confirmed."
        case .browserUnavailable: "The unsubscribe page could not be opened in your default browser."
        }
    }
}

/// A future backend can implement this interface without changing the reader UI.
@MainActor
protocol MailUnsubscribeRequesting {
    func requestOneClick(for message: MailMessage) async throws
    func validateBrowserURL(_ url: URL) async throws -> URL
}

@MainActor
final class MailUnsubscribeService: MailUnsubscribeRequesting {
    private let session: URLSession
    private let resolveHost: @Sendable (String) async throws -> [String]

    init(configuration: URLSessionConfiguration = .ephemeral,
         resolveHost: @escaping @Sendable (String) async throws -> [String] = { host in try await MailUnsubscribeURLPolicy.resolveHost(host) }) {
        // Never share provider authorization, browser cookies, cached credentials,
        // or a persistent session with a sender-controlled endpoint (RFC 8058).
        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.httpCookieAcceptPolicy = .never
        isolated.urlCredentialStorage = nil
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        isolated.httpAdditionalHeaders = [:]
        isolated.timeoutIntervalForRequest = 20
        isolated.timeoutIntervalForResource = 30
        isolated.waitsForConnectivity = false
        session = URLSession(configuration: isolated, delegate: MailUnsubscribeSessionDelegate(), delegateQueue: nil)
        self.resolveHost = resolveHost
    }

    deinit { session.invalidateAndCancel() }

    static func options(for message: MailMessage) -> MailUnsubscribeOptions {
        guard !message.isOutgoing, !message.isDraft, let headers = message.unsubscribeHeaders else {
            return .init(oneClickURL: nil, methods: [], explanation: nil)
        }
        return MailUnsubscribeParser.options(headers, providerTrusted: false)
    }

    func requestOneClick(for message: MailMessage) async throws {
        // Cached headers are not cryptographic proof. The workspace server
        // verifies raw DKIM and owns every one-click unsubscribe request.
        throw MailUnsubscribeError.unsupported
    }

    func validateBrowserURL(_ url: URL) async throws -> URL {
        try await validatePublicDestination(url)
        try Task.checkCancellation()
        return url
    }

    private func validatePublicDestination(_ url: URL) async throws {
        guard let checked = MailUnsubscribeURLPolicy.webURL(url.absoluteString), checked == url,
              let host = url.host else { throw MailUnsubscribeError.unsafeDestination }
        try Task.checkCancellation()
        // This rejects names currently resolving to private networks, but
        // URLSession resolves again. It is a preflight, not a pinned DNS/SSRF
        // boundary; a backend transport must pin the validated addresses.
        let addresses = try await resolveHost(host)
        try Task.checkCancellation()
        guard !addresses.isEmpty else { throw MailUnsubscribeError.unresolvedHost }
        guard addresses.allSatisfy(MailUnsubscribeURLPolicy.isPublicAddress) else { throw MailUnsubscribeError.unsafeDestination }
    }
}

nonisolated final class MailUnsubscribeSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // RFC 8058 forbids redirecting one-click requests. Never change a POST
        // into a GET or pass its opaque subscriber token to a second endpoint.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

nonisolated enum MailUnsubscribeParser {
    static func options(_ headers: MailUnsubscribeHeaders, providerTrusted: Bool) -> MailUnsubscribeOptions {
        guard headers.listUnsubscribe.count == 1,
              let raw = unfold(headers.listUnsubscribe[0]), raw.utf8.count <= 32_768 else {
            return .init(oneClickURL: nil, methods: [], explanation: "The sender supplied ambiguous or invalid unsubscribe headers.")
        }
        let targets = listTargets(raw)
        var methods: [MailUnsubscribeMethod] = []
        for target in targets {
            let method: MailUnsubscribeMethod?
            if let url = MailUnsubscribeURLPolicy.webURL(target) { method = .web(url) }
            else if let email = emailTarget(target) { method = .email(email) }
            else { method = nil }
            if let method, !methods.contains(method) { methods.append(method) }
        }

        let post = headers.listUnsubscribePost.count == 1 ? unfold(headers.listUnsubscribePost[0])?.trimmingCharacters(in: .whitespaces) : nil
        let requestsOneClick = post?.caseInsensitiveCompare("List-Unsubscribe=One-Click") == .orderedSame
        let explanation: String?
        if methods.isEmpty { explanation = "This message has no supported unsubscribe email or public website address." }
        else if requestsOneClick { explanation = "One-click requires cryptographic verification through your workspace. You can use the sender’s email or website option." }
        else { explanation = nil }
        return .init(oneClickURL: nil, methods: methods, explanation: explanation)
    }

    /// RFC 2369: angle brackets, ordered alternatives, CFWS, and stop on a
    /// malformed item. Whitespace accidentally inserted inside a URL is ignored.
    static func listTargets(_ header: String) -> [String] {
        let characters = Array(header)
        var index = 0
        var result: [String] = []
        while index < characters.count && result.count < 20 {
            guard skipCommentsAndWhitespace(characters, index: &index), index < characters.count,
                  characters[index] == "<" else { break }
            index += 1
            var target = ""
            while index < characters.count && characters[index] != ">" {
                let character = characters[index]
                if character == "<" { return result }
                if !character.isWhitespace { target.append(character) }
                index += 1
            }
            guard index < characters.count, !target.isEmpty else { break }
            result.append(target)
            index += 1
            guard skipCommentsAndWhitespace(characters, index: &index), index < characters.count,
                  characters[index] == "," else { break }
            index += 1
        }
        return result.count == 20 && index < characters.count ? [] : result
    }

    static func emailTarget(_ target: String) -> MailUnsubscribeEmail? {
        guard target.utf8.count <= 8_192, URL(string: target, encodingInvalidCharacters: false) != nil,
              let components = URLComponents(string: target),
              components.scheme?.lowercased() == "mailto", components.host == nil,
              components.fragment == nil, components.user == nil, components.password == nil,
              let address = components.percentEncodedPath.removingPercentEncoding,
              isEmailAddress(address) else { return nil }
        var subject = ""
        var body = ""
        var seen: Set<String> = []
        for item in components.queryItems ?? [] {
            let key = item.name.lowercased()
            guard ["subject", "body"].contains(key), seen.insert(key).inserted, let value = item.value else { return nil }
            if key == "subject" {
                guard value.utf8.count <= 998, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
                subject = value
            } else {
                guard value.utf8.count <= 4_096,
                      !value.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }) else { return nil }
                body = value
            }
        }
        return .init(recipients: [address], subject: subject, body: body)
    }

    private static func isEmailAddress(_ address: String) -> Bool {
        guard address.utf8.count <= 254, !address.contains("\r"), !address.contains("\n") else { return false }
        let pieces = address.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, pieces[0].utf8.count <= 64,
              !pieces[0].hasPrefix("."), !pieces[0].hasSuffix("."), !pieces[0].contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.!#$%&'*+-/=?^_`{|}~")
        return pieces[0].unicodeScalars.allSatisfy(allowed.contains) && MailUnsubscribeURLPolicy.isPublicHostname(String(pieces[1]))
    }

    static func unfold(_ value: String) -> String? {
        guard value.utf8.count <= 32_768 else { return nil }
        let unfolded = value.replacingOccurrences(of: "\r\n[ \t]+", with: " ", options: .regularExpression)
        guard !unfolded.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9) || $0.value == 127 }) else { return nil }
        return unfolded
    }

    private static func skipCommentsAndWhitespace(_ characters: [Character], index: inout Int) -> Bool {
        while index < characters.count {
            if characters[index].isWhitespace { index += 1 }
            else if characters[index] == "(" {
                guard skipComment(characters, index: &index) else { return false }
            } else { break }
        }
        return true
    }

    private static func skipComment(_ characters: [Character], index: inout Int) -> Bool {
        var depth = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\\" {
                guard index < characters.count else { return false }
                index += 1
            } else if character == "(" {
                depth += 1
                if depth > 16 { return false }
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return true }
            }
        }
        return false
    }
}

nonisolated enum MailUnsubscribeURLPolicy {
    static func webURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 8_192,
              !raw.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              !raw.contains("\\"),
              !["%00", "%0a", "%0d", "%5c", "%7f"].contains(where: raw.lowercased().contains),
              let original = URL(string: raw, encodingInvalidCharacters: false),
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.user == nil, components.password == nil, components.fragment == nil,
              let rawHost = components.host else { return nil }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard isPublicHostname(host), rawHost.first != ".",
              components.port == nil || components.port == (scheme == "https" ? 443 : 80) else { return nil }
        components.scheme = scheme
        components.host = host
        return components.url
    }

    static func isPublicHostname(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host.utf8.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."),
              !host.contains(".."), !host.contains(":"), !host.contains("%") else { return false }
        let labels = host.split(separator: ".")
        let blocked = ["localhost", "local", "localdomain", "lan", "internal", "intranet", "home", "test", "invalid", "example", "onion", "arpa"]
        guard labels.count >= 2, let last = labels.last,
              !blocked.contains(String(last)), last.contains(where: { $0.isASCII && $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func resolveHost(_ host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                throw MailUnsubscribeError.unresolvedHost
            }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: buffer))
                }
                cursor = info.pointee.ai_next
            }
            return addresses
        }.value
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            let a = Int(bytes[0]), b = Int(bytes[1]), c = Int(bytes[2])
            return !(a == 0 || a == 10 || a == 127 || a >= 224
                     || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
                     || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                     || (a == 192 && b == 0 && (c == 0 || c == 2)) || (a == 192 && b == 88 && c == 99)
                     || (a == 198 && (b == 18 || b == 19)) || (a == 198 && b == 51 && c == 100)
                     || (a == 203 && b == 0 && c == 113))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        // Permit ordinary global unicast only: no loopback, local, link-local,
        // mapped IPv4, NAT64, multicast, documentation or transition addresses.
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
            if bytes[2] == 0 && bytes[3] <= 0x2f { return false }
        }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false }
        return true
    }
}
