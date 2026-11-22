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
    var timeZone: String? = nil
    let bio: String?
    let links: [Link]
    var recentActivity: [Activity]? = nil
    var talkingPoints: [TalkingPoint]? = nil
    var companyProfile: Company? = nil
    let source: Source?
    let sources: [Source]?
    let citations: [Citation]?

    struct Activity: Decodable, Identifiable, Sendable {
        let title: String
        let url: String
        let date: String?
        let kind: String
        var id: String { url + title }
        var destination: URL? { BackendSenderProfile.publicURL(url) }
        /// "Mar 2026" or "14 Mar 2026" from the source's stated date.
        var displayDate: String? {
            guard let date else { return nil }
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard parts.count >= 2, let month = Calendar(identifier: .gregorian).date(from:
                DateComponents(year: parts[0], month: parts[1], day: parts.count > 2 ? parts[2] : 1)) else { return nil }
            return parts.count > 2 ? month.formatted(.dateTime.day().month(.abbreviated).year())
                : month.formatted(.dateTime.month(.abbreviated).year())
        }
    }
    /// The organization behind the sender's domain, or a matched person's employer.
    struct Company: Decodable, Sendable {
        let name: String
        let domain: String
        let summary: String?
        let industry: String?
        let size: String?
        let funding: String?
        let headquarters: String?
        let website: String?
        let careersUrl: String?
        let hiring: String?
        let news: [News]
        let sourceUrls: [String]

        struct News: Decodable, Identifiable, Sendable {
            let title: String
            let url: String
            let date: String?
            var id: String { url + title }
            var destination: URL? { BackendSenderProfile.publicURL(url) }
            var displayDate: String? {
                Activity(title: title, url: url, date: date, kind: "news").displayDate
            }
        }
        var websiteURL: URL? { website.flatMap(BackendSenderProfile.publicURL) }
        var careersURL: URL? { careersUrl.flatMap(BackendSenderProfile.publicURL) }
    }

    struct TalkingPoint: Decodable, Identifiable, Sendable {
        let text: String
        let sourceUrl: String
        var id: String { sourceUrl + text }
    }

    /// Activity and talking points shown only when their page is a listed source.
    var publicActivity: [Activity] {
        let urls = Set(publicSources.map(\.url))
        return (recentActivity ?? []).filter { $0.destination != nil && urls.contains($0.url) }
    }
    var publicTalkingPoints: [TalkingPoint] {
        let urls = Set(publicSources.map(\.url))
        return (talkingPoints ?? []).filter { urls.contains($0.sourceUrl) }
    }
    /// The company, shown only when it cites a listed source.
    var publicCompany: Company? {
        guard let company = companyProfile else { return nil }
        let urls = Set(publicSources.map(\.url))
        return company.sourceUrls.contains(where: urls.contains) ? company : nil
    }
    var hasPerson: Bool {
        [name, jobTitle, company, location, bio].contains { $0?.isEmpty == false } || !publicLinks.isEmpty
    }

    /// The sender's zone, only alongside a cited location.
    var localTimeZone: TimeZone? {
        guard location != nil, !sources(for: "location").isEmpty else { return nil }
        return timeZone.flatMap(TimeZone.init(identifier:))
    }

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
        } || !publicLinks.isEmpty || !publicActivity.isEmpty || publicCompany != nil
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
