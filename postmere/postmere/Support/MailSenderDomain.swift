import Foundation

enum MailSenderDomain {
    static func email(in address: String) -> String? {
        let parsed = MailAddressList(address)
        guard parsed.addresses.count == 1, parsed.invalid.isEmpty else { return nil }
        return parsed.addresses[0].lowercased()
    }
}

/// Keep potentially unique mail subdomains out of icon requests. Include the PSL's
/// private section so two tenants of the same hosting service stay distinct.
nonisolated struct WebsiteIconDomains: Sendable {
    private let rules: Set<String>

    static let bundled = Task.detached(priority: .utility) {
        let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat")
        return WebsiteIconDomains(listURL: url)
    }

    init(listURL: URL?) {
        guard let listURL, let list = try? String(contentsOf: listURL, encoding: .utf8) else {
            rules = [] // A missing list must never cause the whole hostname to be sent.
            return
        }
        rules = Set(list.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard !line.hasPrefix("//") else { return nil }
            if line.utf8.allSatisfy({ $0 < 128 }) { return String(line) }
            let prefix = line.hasPrefix("*.") ? "*." : line.hasPrefix("!") ? "!" : ""
            guard let ascii = URL(string: "https://\(line.dropFirst(prefix.count))")?.host(percentEncoded: false) else { return nil }
            return prefix + ascii
        })
    }

    private static let sharedMailboxDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "aol.com", "aim.com",
        "outlook.com", "outlook.de", "outlook.fr", "outlook.it", "outlook.es",
        "hotmail.com", "hotmail.co.uk", "hotmail.fr", "hotmail.de", "hotmail.it", "hotmail.es", "hotmail.ca",
        "live.com", "live.co.uk", "live.ca", "live.fr", "live.nl", "live.de", "live.it", "msn.com",
        "yahoo.com", "yahoo.co.uk", "yahoo.co.jp", "yahoo.fr", "yahoo.de", "yahoo.it", "yahoo.es",
        "yahoo.ca", "yahoo.in", "yahoo.com.au", "yahoo.com.br", "yahoo.com.mx", "ymail.com", "rocketmail.com",
        "proton.me", "protonmail.com", "protonmail.ch", "pm.me", "fastmail.com", "fastmail.fm",
        "gmx.com", "gmx.de", "gmx.net", "web.de", "mail.com", "hey.com", "mail.ru", "yandex.ru",
        "yandex.com", "qq.com", "163.com", "126.com", "zoho.com", "tuta.com", "tuta.io", "tutanota.com",
        "example.com", "example.net", "example.org"
    ]

    /// Expects one normalized address from MailAddressList. Only known public
    /// suffixes qualify, excluding local names, IP literals and reserved TLDs.
    func website(for email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let host = email[email.index(after: at)...]
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count > 1,
              labels.last != "onion", labels.last != "arpa",
              labels.allSatisfy({ (1...63).contains($0.utf8.count) }) else { return nil }

        var suffixLength = 0
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.contains("!" + suffix) {
                suffixLength = labels.count - index - 1
                break
            }
            if rules.contains(suffix) { suffixLength = max(suffixLength, labels.count - index) }
            if index > 0, rules.contains("*." + suffix) {
                suffixLength = max(suffixLength, labels.count - index + 1)
            }
        }
        guard suffixLength > 0, suffixLength < labels.count else { return nil }
        let registrant = labels.count - suffixLength - 1
        let domain = labels[registrant...].joined(separator: ".")
        guard !Self.sharedMailboxDomains.contains(domain) else { return nil }
        return domain
    }
}
