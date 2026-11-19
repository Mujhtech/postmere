import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class MailRemoteParticipantImages {
    enum Source {
        case gravatar, websiteIcon

        var preference: String {
            switch self {
            case .gravatar: "useGravatarParticipantPhotos"
            case .websiteIcon: "showParticipantWebsiteIcons"
            }
        }
    }

    static let gravatar = MailRemoteParticipantImages(source: .gravatar)
    static let websiteIcons = MailRemoteParticipantImages(source: .websiteIcon)

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            preferences.set(enabled, forKey: source.preference)
            revision += 1
            if !enabled {
                for task in inFlight.values { task.cancel() }
                inFlight.removeAll()
                cache.removeAllObjects()
                session?.invalidateAndCancel()
                session = nil
            }
        }
    }
    private(set) var revision = 0
    @ObservationIgnored private let source: Source
    @ObservationIgnored private let iconDomains: WebsiteIconDomains?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let configuration: URLSessionConfiguration
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private let cache = NSCache<NSString, CachedPhoto>()
    @ObservationIgnored private var inFlight: [URL: Task<CachedPhoto, Never>] = [:]

    init(source: Source, preferences: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral,
         iconDomains: WebsiteIconDomains? = nil) {
        self.source = source
        self.iconDomains = iconDomains
        self.preferences = preferences
        if let saved = preferences.object(forKey: source.preference) as? Bool {
            enabled = saved
        } else if source == .websiteIcon {
            // Preserve an existing user's choice to avoid automatic remote loads
            // when introducing the independent website-icons preference.
            let automatic = preferences.object(forKey: "loadRemoteMailImagesAutomatically") as? Bool ?? true
            enabled = automatic
            preferences.set(automatic, forKey: source.preference)
        } else {
            enabled = false
        }
        let configuration = BackendHTTPClient.isolatedConfiguration(configuration)
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        self.configuration = configuration
        cache.countLimit = 256
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    struct Photo {
        let image: CGImage
        /// Set only for a domain-level website icon.
        let website: String?
    }

    func photo(email address: String) async -> Photo? {
        guard enabled, !Task.isCancelled, let email = MailSenderDomain.email(in: address) else { return nil }
        let version = revision
        let website: String?
        let url: URL
        switch source {
        case .gravatar:
            let hash = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
            url = URL(string: "https://gravatar.com/avatar/\(hash)?s=320&d=404&r=g")!
            website = nil
        case .websiteIcon:
            let domains: WebsiteIconDomains
            if let iconDomains { domains = iconDomains } else { domains = await WebsiteIconDomains.bundled.value }
            guard enabled, version == revision, !Task.isCancelled,
                  let domain = domains.website(for: email) else { return nil }
            url = URL(string: "https://icons.bitwarden.net")!.appending(path: domain).appending(path: "icon.png")
            website = domain
        }
        guard let image = await image(at: url, version: version) else { return nil }
        return Photo(image: image, website: website)
    }

    private func image(at url: URL, version: Int) async -> CGImage? {
        let key = url.absoluteString as NSString
        if let hit = cache.object(forKey: key), hit.expires > .now { return hit.image }
        if let pending = inFlight[url] {
            let hit = await pending.value
            return enabled && version == revision && !Task.isCancelled ? hit.image : nil
        }
        let session = self.session ?? URLSession(configuration: configuration, delegate: BackendNoRedirect(), delegateQueue: nil)
        self.session = session
        let allowICO = source == .websiteIcon
        let task = Task.detached(priority: .utility) { await Self.download(url: url, session: session, allowICO: allowICO) }
        inFlight[url] = task
        let result = await task.value
        guard enabled && version == revision else { return nil }
        inFlight.removeValue(forKey: url)
        let cost = result.image.map { $0.bytesPerRow * $0.height } ?? 1
        cache.setObject(result, forKey: key, cost: cost)
        return Task.isCancelled ? nil : result.image
    }

    private nonisolated final class CachedPhoto: Sendable {
        let image: CGImage?
        let expires: Date
        init(_ image: CGImage? = nil, lifetime: TimeInterval = 60) {
            self.image = image
            expires = .now.addingTimeInterval(lifetime)
        }
    }

    private nonisolated static func download(url: URL, session: URLSession, allowICO: Bool) async -> CachedPhoto {
        guard !Task.isCancelled else { return CachedPhoto() }
        let limit = 1024 * 1024
        do {
            let (bytes, response) = try await session.bytes(from: url)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return CachedPhoto() }
            if http.statusCode == 404 { return CachedPhoto(lifetime: 6 * 3600) }
            guard http.statusCode == 200, response.mimeType?.hasPrefix("image/") == true,
                  response.expectedContentLength <= limit else { return CachedPhoto() }
            var data = Data()
            for try await byte in bytes {
                guard !Task.isCancelled, data.count < limit else { return CachedPhoto() }
                data.append(byte)
            }
            guard let image = thumbnail(from: data, allowICO: allowICO) else { return CachedPhoto() }
            return CachedPhoto(image, lifetime: 24 * 3600)
        } catch { return CachedPhoto() }
    }

    private nonisolated static func thumbnail(from data: Data, allowICO: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let rawType = CGImageSourceGetType(source), let type = UTType(rawType as String) else { return nil }
        let isIcon = allowICO && type == .ico
        guard isIcon || [UTType.png, .jpeg, .gif, .webP].contains(type) else { return nil }

        // A favicon may contain several bitmap sizes. Prefer the largest bounded
        // representation; for animated photo formats only read the first frame.
        let count = isIcon ? CGImageSourceGetCount(source) : 1
        guard (1...64).contains(count) else { return nil }
        var chosen: Int?
        var largest = 0
        for index in 0..<count {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                  (1...4096).contains(width), (1...4096).contains(height) else { continue }
            let area = width * height
            if area > largest && area <= 4_194_304 { chosen = index; largest = area }
        }
        guard let chosen else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceShouldCacheImmediately: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 320]
        return CGImageSourceCreateThumbnailAtIndex(source, chosen, options as CFDictionary)
    }
}
