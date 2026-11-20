import AppKit
import ImageIO

nonisolated struct BackendSenderMarkResponse: Decodable, Sendable {
    let verifiedSenderMark: BackendSenderMark?
}

/// Malformed optional artwork must never interrupt ordinary mail synchronization.
nonisolated struct BackendSenderMark: Decodable, Sendable {
    let domain: String?
    let provider: String?
    let verifiedBy: String?
    let expiresAt: Date?
    let logoSvg: String?

    enum CodingKeys: CodingKey { case domain, provider, verifiedBy, expiresAt, logoSvg }

    init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        domain = try? fields?.decode(String.self, forKey: .domain)
        provider = try? fields?.decode(String.self, forKey: .provider)
        verifiedBy = (try? fields?.decode(String.self, forKey: .verifiedBy))
            ?? (fields?.contains(.verifiedBy) == true ? "" : "postmere")
        expiresAt = try? fields?.decode(Date.self, forKey: .expiresAt)
        logoSvg = try? fields?.decode(String.self, forKey: .logoSvg)
    }

    @concurrent func render(for message: MailMessage, identity: RemoteAccountIdentity) async -> MailVerifiedSenderMark? {
        localMark(for: message, identity: identity)
    }

    func localMark(for message: MailMessage, identity: RemoteAccountIdentity) -> MailVerifiedSenderMark? {
        guard provider == "gmail", identity.provider == "gmail", identity.localID == message.account,
              let messageID = message.backendMessageID, let expiresAt, expiresAt > .now, let domain,
              message.incomingSenderDomain == domain, let verifiedBy, ["gmail", "postmere"].contains(verifiedBy),
              let logoSvg, logoSvg.utf8.count <= 43_692, let data = Data(base64Encoded: logoSvg), data.count <= 32_768,
              let png = SenderMarkArtwork.rasterize(data) else { return nil }
        return MailVerifiedSenderMark(messageID: messageID, account: identity.localID, domain: domain,
                                      verifier: verifiedBy == "gmail" ? "Gmail" : "Postmere",
                                      expiresAt: expiresAt, logoPNG: png)
    }
}

/// Accept self-contained vector shapes and local paint references. Rasterize before storing or displaying.
private nonisolated final class SenderMarkArtwork: NSObject, XMLParserDelegate {
    private static let elements: Set<String> = [
        "svg", "g", "title", "desc", "defs", "path", "rect", "circle", "ellipse", "polyline", "polygon",
        "line", "linearGradient", "radialGradient", "stop", "clipPath"
    ]
    private static let attributes: Set<String> = [
        "xmlns", "xmlns:xlink", "xml:space", "version", "baseProfile", "id", "viewBox", "preserveAspectRatio",
        "x", "y", "width", "height", "rx", "ry", "cx", "cy", "r", "fx", "fy", "x1", "x2", "y1", "y2",
        "d", "points", "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-linejoin",
        "stroke-linecap", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "stroke-opacity",
        "opacity", "transform", "clip-path", "clip-rule", "clipPathUnits", "gradientUnits", "gradientTransform",
        "spreadMethod", "offset", "stop-color", "stop-opacity", "color"
    ]
    private var depth = 0
    private var count = 0


    static func rasterize(_ data: Data) -> Data? {
        guard let xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        // Parse the same UTF-8 bytes with both decoders. Reject ambiguous declarations.
        guard !xml.contains("\u{0}"),
              xml.range(of: #"<\?xml[^?]+encoding\s*=\s*["'](?!utf-8["'])"#,
                        options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let artwork = SenderMarkArtwork()
        parser.delegate = artwork
        guard parser.parse(), parser.parserError == nil, artwork.count > 1,
              let image = NSImage(data: data) else { return nil }
        var bounds = CGRect(x: 0, y: 0, width: 160, height: 160)
        guard let cg = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil),
              cg.width <= 512, cg.height <= 512 else { return nil }
        let result = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, cg, nil)
        guard CGImageDestinationFinalize(target) else { return nil }
        return result as Data
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        depth += 1
        count += 1
        guard Self.elements.contains(element), depth <= 32, count <= 3_000 else { parser.abortParsing(); return }
        if depth == 1 {
            guard element == "svg", attributes["xmlns"] == "http://www.w3.org/2000/svg",
                  attributes["baseProfile"] == "tiny-ps", attributes["version"] == "1.2" else {
                parser.abortParsing()
                return
            }
            if let viewBox = attributes["viewBox"] {
                let parts = viewBox.split(whereSeparator: { $0.isWhitespace || $0 == "," })
                let numbers = parts.compactMap { Double($0) }
                guard parts.count == 4, numbers.count == 4, numbers.allSatisfy(\.isFinite),
                      numbers[2] > 0, numbers[3] > 0 else { parser.abortParsing(); return }
            } else if attributes["width"] == nil || attributes["height"] == nil {
                parser.abortParsing()
                return
            }
            for field in ["width", "height"] {
                guard let raw = attributes[field] else { continue }
                let value = raw.hasSuffix("px") ? String(raw.dropLast(2)) : raw
                guard let n = Double(value), n.isFinite, n > 0, n <= 4096 else { parser.abortParsing(); return }
            }
        }
        for (key, value) in attributes {
            guard Self.attributes.contains(key) else { parser.abortParsing(); return }
            let paint = value.replacingOccurrences(of: #"url\(\s*['"]?#[\w.:-]+['"]?\s*\)"#, with: "",
                                                   options: [.regularExpression, .caseInsensitive])
            if paint.localizedCaseInsensitiveContains("url") || paint.contains("@") || paint.contains("\\") || paint.contains("/*") {
                parser.abortParsing()
                return
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        parser.abortParsing()
    }
}
