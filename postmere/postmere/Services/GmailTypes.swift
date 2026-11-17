import Foundation
import CryptoKit

nonisolated enum GmailError: LocalizedError, Sendable {
    case configuration(String)
    case notConnected
    case cancelled
    case authorization(String)
    case invalidResponse
    case http(Int, String)
    case invalidMessage(String)
    case keychain(Int32)
    case sendUnconfirmed

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .authorization(let message), .invalidMessage(let message): message
        case .notConnected: "Connect your Gmail account before continuing."
        case .cancelled: "Google sign-in was cancelled."
        case .invalidResponse: "Google returned a response Postmere could not read. Try syncing again."
        case .http(let code, let message): "Gmail (\(code)): \(message)"
        case .keychain(let code): "Postmere could not access its secure Keychain item (\(code)). Unlock your Mac and try again."
        case .sendUnconfirmed: "Google did not confirm whether this email was sent. Check Gmail’s Sent folder before trying again to avoid a duplicate."
        }
    }
}

nonisolated struct GmailCredentials: Codable, Sendable {
    var clientID: String
    var clientSecret: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
    var email: String?
    var displayName: String?
    var scope: String?
}

nonisolated struct GmailConnectionInfo: Sendable {
    var clientID: String
    var hasClientSecret: Bool
    var email: String?
    var displayName: String?
    var hasTokens: Bool
}

nonisolated struct GmailTokenResponse: Decodable, Sendable {
    let access_token: String
    let expires_in: Double
    let refresh_token: String?
    let scope: String?
    let token_type: String?
}

nonisolated struct GmailProfile: Decodable, Sendable {
    let emailAddress: String
    let messagesTotal: Int?
    let historyId: String?
}

nonisolated struct GmailMessageList: Decodable, Sendable {
    let messages: [GmailMessageReference]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

nonisolated struct GmailMessageReference: Codable, Sendable {
    let id: String
    let threadId: String?
}

nonisolated struct GmailWireMessage: Codable, Sendable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    var payload: GmailMessagePart?
}

nonisolated struct GmailMessagePart: Codable, Sendable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [GmailHeader]?
    var body: GmailPartBody?
    var parts: [GmailMessagePart]?

    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var isAttachment: Bool {
        !(filename ?? "").isEmpty || header("Content-Disposition")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
    }
}

nonisolated struct GmailHeader: Codable, Sendable {
    let name: String
    let value: String
}

nonisolated struct GmailPartBody: Codable, Sendable {
    let attachmentId: String?
    let size: Int?
    var data: String?
}

nonisolated struct GmailSyncResult: Sendable {
    var messages: [GmailWireMessage]
    var hasMore: Bool
}

nonisolated struct GmailVerificationResult: Sendable {
    var messages: [GmailWireMessage]
    var unavailableMessageIDs: Set<String>
}

nonisolated struct GmailSendRequest: Encodable, Sendable {
    var raw: String
    var threadId: String?
}

nonisolated struct GmailModifyRequest: Encodable, Sendable {
    var addLabelIds: [String]
    var removeLabelIds: [String]
}

nonisolated enum GmailEncoding {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        let base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }

    static func stableID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func form(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let string = parameters.keys.sorted().map { key in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(parameters[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(string.utf8)
    }

    static func decodeText(_ data: Data, charset: String? = nil) -> String {
        let encoding: String.Encoding
        switch charset?.lowercased() {
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252": encoding = .windowsCP1252
        case "us-ascii", "ascii": encoding = .ascii
        case "utf-16": encoding = .utf16
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    static func decodeHeader(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return input }
        var result = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let full = Range(match.range, in: result), let charset = Range(match.range(at: 1), in: input),
                  let mode = Range(match.range(at: 2), in: input), let encoded = Range(match.range(at: 3), in: input) else { continue }
            let payload = String(input[encoded])
            let data: Data?
            if input[mode].lowercased() == "b" {
                data = Data(base64Encoded: payload)
            } else {
                let bytes = Array(payload.replacingOccurrences(of: "_", with: " ").utf8)
                var output: [UInt8] = []; var index = 0
                while index < bytes.count {
                    if bytes[index] == 61, index + 2 < bytes.count,
                       let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                        output.append(byte); index += 3
                    } else { output.append(bytes[index]); index += 1 }
                }
                data = Data(output)
            }
            if let data { result.replaceSubrange(full, with: decodeText(data, charset: String(input[charset]))) }
        }
        return result
    }

    /// Plain-text fallback only. Never invokes WebKit/HTML importers or loads remote resources.
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|li|tr|h[1-6])\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let full = Range(match.range, in: text), let valueRange = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[valueRange]); let hex = value.hasPrefix("x")
                if let scalar = UInt32(hex ? String(value.dropFirst()) : value, radix: hex ? 16 : 10).flatMap(Unicode.Scalar.init) {
                    text.replaceSubrange(full, with: String(scalar))
                }
            }
        }
        return text.replacingOccurrences(of: #"\n[\t ]+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
