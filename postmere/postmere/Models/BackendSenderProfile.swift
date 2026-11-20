import Foundation

nonisolated struct SenderProfileRequest: Encodable, Sendable {
    let refresh: Bool
    static let method = "POST"
    static func path(messageID: UUID) -> String { "/v1/mail/messages/\(messageID.uuidString)/sender-profile" }
}

nonisolated struct BackendSenderProfileResponse: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case matched
        case notFound = "not_found"
        case unconfigured, disabled
    }
    let email: String
    let status: Status
    let profile: BackendSenderProfile?
    let checkedAt: Date?

    func validated(for expectedEmail: String) throws -> Self {
        guard email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedEmail.lowercased() else {
            throw SenderProfileResponseError.mismatchedSender
        }
        if status == .matched {
            guard let profile, !profile.publicSources.isEmpty, profile.hasDetails else {
                throw SenderProfileResponseError.unsupportedProfile
            }
        } else if profile != nil { throw SenderProfileResponseError.unsupportedProfile }
        return self
    }
}

nonisolated struct BackendSenderProfile: Decodable, Sendable {
    let name: String?
    let jobTitle: String?
    let company: String?
    let location: String?
    let bio: String?
    let links: [Link]
    let source: Source?
    let sources: [Source]?
    let citations: [Citation]?

    struct Link: Decodable, Identifiable, Sendable {
        let label: String
        let url: String
        var id: String { url }
        var destination: URL? { BackendSenderProfile.publicURL(url) }
    }
    struct Source: Decodable, Identifiable, Sendable {
        let name: String
        let url: String
        var id: String { url }
        var destination: URL? { BackendSenderProfile.publicURL(url) }
        var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? destination?.host ?? "Source" : name }
    }
    struct Citation: Decodable, Sendable {
        let field: String
        let sourceUrls: [String]
    }
    var publicSources: [Source] {
        var seen: Set<String> = []
        return (sources ?? source.map { [$0] } ?? []).filter { $0.destination != nil && seen.insert($0.url).inserted }
    }
    var publicLinks: [Link] {
        guard !sources(for: "links").isEmpty else { return [] }
        var seen: Set<String> = []
        let sourceURLs = Set(publicSources.map(\.url))
        return links.filter { $0.destination != nil && sourceURLs.contains($0.url) && seen.insert($0.url).inserted }
    }
    var hasDetails: Bool {
        let fields = [("name", name), ("job_title", jobTitle), ("company", company), ("location", location), ("bio", bio)]
        return fields.contains { field, value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && !sources(for: field).isEmpty
        } || !publicLinks.isEmpty
    }
    func sources(for field: String) -> [Source] {
        let urls = Set((citations ?? []).filter { $0.field == field }.flatMap(\.sourceUrls))
        return publicSources.filter { urls.contains($0.url) }
    }
    // These are user-opened public source links; never allow executable schemes,
    // embedded credentials, or links to private/local hosts from researched text.
    static func publicURL(_ text: String) -> URL? {
        guard text.utf8.count <= 4_096, !text.contains("\\"), !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let decoded = text.removingPercentEncoding, !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), let url = URL(string: text), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, let host = url.host?.lowercased(), host.contains("."),
              !host.contains(":"), host.contains(where: { $0.isLetter }),
              ![".localhost", ".local", ".internal", ".test", ".invalid", ".home", ".lan", ".localdomain", ".intranet", ".corp", ".onion", ".arpa", ".example"].contains(where: host.hasSuffix),
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
}

nonisolated enum SenderProfileResponseError: LocalizedError {
    case mismatchedSender, unsupportedProfile
    var errorDescription: String? {
        "Sender details could not be matched to this message. Try again."
    }
}
