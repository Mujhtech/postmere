import Foundation

@main
private struct SenderContextChecks {
    @MainActor
    static func main() async throws {
        let domains = WebsiteIconDomains(listURL: URL(filePath: "Resources/public_suffix_list.dat"))
        let senders: [(String, String?)] = [
            ("Shipping <notice@unique.courier.co.uk>", "courier.co.uk"),
            ("News <updates@E.STRIPE.COM>", "stripe.com"),
            ("studio@mail.live.studio", "live.studio"), ("hi@account.github.io", "account.github.io"), ("hello@github.io", nil),
            ("hi@public.city.kawasaki.jp", "city.kawasaki.jp"), ("hi@brand.kawasaki.jp", nil),
            ("one@xn--bcher-kva.de", "xn--bcher-kva.de"), ("me@shop.xn--55qx5d.cn", "shop.xn--55qx5d.cn"),
            ("me@googlemail.com", nil), ("You <me@yahoo.co.uk>", nil), ("you@icloud.com", nil),
            ("foo@192.168.0.10", nil), ("test@dev.local", nil), ("x@co.uk", nil),
            ("x@myrouter.home.arpa", nil), ("private@somehiddenservice.onion", nil),
            ("hi@demo.example.com", nil), ("one@stripe.com, two@stripe.com", nil)
        ]
        for (address, expected) in senders {
            let domain = MailSenderDomain.email(in: address).flatMap { domains.website(for: $0) }
            precondition(domain == expected, "Unexpected domain for \(address): \(domain ?? "nil")")
        }
        precondition(WebsiteIconDomains(listURL: nil).website(for: "hello@stripe.com") == nil)
        print("PASS: public suffixes, private tenants, wildcards and exceptions; excludes personal and private domains")
        try await websiteIcons(domains)
        try await gravatarPhotos()
        let priorAccounts = RemoteAccountRegistry.accounts
        defer { RemoteAccountRegistry.accounts = priorAccounts }
        let accountA = RemoteAccountIdentity(localID: "remote:workspace-a:account-a", accountID: UUID(), scope: "workspace-a", email: "me@example.com", displayName: "Me", provider: "google")
        let accountB = RemoteAccountIdentity(localID: "remote:workspace-b:account-b", accountID: UUID(), scope: "workspace-b", email: "me@example.com", displayName: "Me", provider: "google")
        RemoteAccountRegistry.accounts = [accountA, accountB]
        let thread = UUID()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let file = MailAttachment(name: "Proposal.pdf", detail: "PDF", localURL: nil)
        let incoming = MailMessage(sender: "Ada", senderEmail: "Ada@example.com", initials: "A", subject: "Project",
            preview: "Proposal attached", paragraphs: ["Hello"], timeLabel: "9:00", account: accountA.localID,
            toRecipients: ["me@example.com"], bccRecipients: ["must-not-suggest@example.com"], attachments: [file], conversationID: thread,
            sentAt: now.addingTimeInterval(-86_400), providerAccountEmail: "me@example.com")
        let outgoing = MailMessage(sender: "Me", senderEmail: "me@example.com", initials: "M", subject: "Re: Project",
            preview: "Thanks", paragraphs: ["Thanks"], timeLabel: "10:00", mailbox: .sent, account: accountA.localID,
            isOutgoing: true, toRecipients: ["ADA@example.com"], ccRecipients: ["grace@example.com"], conversationID: thread,
            sentAt: now, providerAccountEmail: "me@example.com")
        var otherWorkspace = incoming
        otherWorkspace.id = UUID(); otherWorkspace.account = accountB.localID
        otherWorkspace.senderEmail = "secret@example.com"; otherWorkspace.subject = "Private in workspace B"
        var pending = incoming
        pending.id = UUID(); pending.senderEmail = "pending@example.com"; pending.workflow.screeningState = .pending
        var trashed = incoming
        trashed.id = UUID(); trashed.senderEmail = "trashed@example.com"; trashed.mailbox = .trash
        let store = MailStore(messages: [incoming, outgoing, otherWorkspace, pending, trashed])
        store.draftAccount = MailAccount(rawValue: accountA.localID)!
        store.draftProviderAccountEmail = "me@example.com"
        let scopeA = MailContactIdentity.accountKey(for: incoming)
        let scopeB = MailContactIdentity.accountKey(for: otherWorkspace)
        precondition(scopeA != scopeB)
        let context = store.senderContext(email: "ADA@example.com", accountKey: scopeA)
        precondition(context.conversations.count == 1 && context.messageCount == 2 && context.attachments.count == 1)
        precondition(context.conversations[0].latestMessage.id == outgoing.id && context.attachments[0].attachment.id == file.id)
        precondition(context.lastContact == now)
        let suggestions = store.recipientSuggestions(for: "", excluding: [])
        precondition(suggestions.contains { $0.email == "ada@example.com" } && suggestions.contains { $0.email == "grace@example.com" })
        precondition(!suggestions.contains { ["me@example.com", "secret@example.com", "pending@example.com", "trashed@example.com", "must-not-suggest@example.com"].contains($0.email) })
        precondition(store.recipientSuggestions(for: "aD").first?.email == "ada@example.com")
        precondition(!store.recipientSuggestions(for: "", excluding: ["ADA@example.com"]).contains { $0.email == "ada@example.com" })
        let grace = suggestions.first { $0.email == "grace@example.com" }!
        let completion = MailRecipientSuggestions.replacingCurrentToken(in: "\"Doe, Ada\" <ada@example.com>, gr", with: grace)
        precondition(completion == "\"Doe, Ada\" <ada@example.com>, grace@example.com, ")
        print("PASS: scoped conversations/files, recent suggestions, screening/trash/Bcc exclusions, and quoted recipient completion")

        let lookup = MailRecipientLookup()
        let draftSource = store.draftRecipientSource!
        precondition(draftSource.accountKey == scopeA)
        let ownAddresses = [accountA.email]
        let typed = await lookup.matches("ad", source: draftSource, messages: store.messages, ownAddresses: ownAddresses)
        precondition(typed.map(\.email) == ["ada@example.com"])
        let selected = await lookup.matches("\"Doe, Ada\" <ada@example.com>; ad", source: draftSource,
                                            messages: store.messages, ownAddresses: ownAddresses)
        precondition(selected.isEmpty)
        store.draftAccount = MailAccount(rawValue: accountB.localID)!
        let switched = await lookup.matches("sec", source: store.draftRecipientSource!, messages: store.messages,
                                            ownAddresses: ownAddresses)
        precondition(switched.map(\.email) == ["secret@example.com"])
        store.messages.removeAll { $0.id == otherWorkspace.id }
        let refreshed = await lookup.matches("sec", source: store.draftRecipientSource!, messages: store.messages,
                                             ownAddresses: ownAddresses)
        precondition(refreshed.isEmpty)
        store.draftAccount = MailAccount(rawValue: accountA.localID)!
        print("PASS: composer completions follow typed recipients, sender changes and mailbox edits")

        // History with one person: replies each way, waiting threads, usual hours.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2030, month: 3, day: 4, hour: 9))!
        func mail(_ thread: UUID, at hours: Double, fromAda: Bool, subject: String = "Role") -> MailMessage {
            var message = fromAda ? incoming : outgoing
            message.id = UUID(); message.conversationID = thread; message.subject = subject
            message.sentAt = day.addingTimeInterval(hours * 3_600)
            message.attachments = []
            return message
        }
        let roleThread = UUID(), introThread = UUID(), followThread = UUID()
        let history = [
            mail(roleThread, at: 0, fromAda: true),            // Ada 09:00
            mail(roleThread, at: 2, fromAda: false),           // you reply after 2h
            mail(roleThread, at: 5, fromAda: true),            // Ada replies after 3h, 14:00
            mail(introThread, at: 24, fromAda: false, subject: "Intro"),
            mail(introThread, at: 25, fromAda: true, subject: "Intro"),   // Ada replies after 1h, 10:00
            mail(followThread, at: 48, fromAda: true, subject: "Next steps"), // 09:00, waiting on you
            mail(followThread, at: 72.5, fromAda: true, subject: "Next steps"), // 09:30
        ]
        let relationship = MailRelationship.build(email: "ADA@example.com", accountKey: scopeA, messages: history + [otherWorkspace],
                                                   calendar: utc, now: day.addingTimeInterval(80 * 3_600))
        precondition(relationship.fromThem == 5 && relationship.fromYou == 2 && relationship.conversations == 3, "\(relationship)")
        precondition(relationship.firstContact == day && relationship.lastSubject == "Next steps")
        precondition(relationship.theirReplyTime == 2 * 3_600, "median of 3h and 1h: \(String(describing: relationship.theirReplyTime))")
        precondition(relationship.yourReplyTime == 2 * 3_600)
        precondition(relationship.waitingOnYou.map(\.subject).sorted() == ["Intro", "Next steps", "Role"] && relationship.waitingOnThem.isEmpty)
        precondition(relationship.usualHour == 9, "most of Ada's mail arrives 9–11: \(String(describing: relationship.usualHour))")
        precondition(MailRelationship.build(email: "nobody@example.com", accountKey: scopeA, messages: history).isEmpty)
        print("PASS: relationship history, reply times, waiting threads and usual hours")

        precondition(store.setSenderVIP(true, email: "ADA@example.com", accountKey: scopeA))
        precondition(store.hasSenderVIP(email: "ada@example.com", accountKey: scopeA))
        precondition(!store.hasSenderVIP(email: "ada@example.com", accountKey: scopeB))
        precondition(store.setSenderVIP(false, email: "ada@example.com", accountKey: scopeA))
        precondition(!store.hasSenderVIP(email: "ada@example.com", accountKey: scopeA))
        RemoteAccountRegistry.accounts = [accountB]
        precondition(store.draftRecipientSource == nil)
        precondition(store.senderContext(email: "ada@example.com", accountKey: scopeA).messageCount == 0)
        precondition(store.recipientSuggestions(for: "", accountKey: scopeA).isEmpty, "Disconnected account data must never be suggested")
        print("PASS: account-scoped VIP changes and disconnected-workspace isolation")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Postmere-Contact-Checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contact-notes.json")
        let notes = MailContactNotesStore(fileURL: url)
        try notes.save("Ask about the launch", for: "ADA@example.com", accountKey: scopeA)
        try notes.save("Separate workspace note", for: "ada@example.com", accountKey: scopeB)
        let reopened = MailContactNotesStore(fileURL: url)
        precondition(reopened.note(for: "ada@example.com", accountKey: scopeA) == "Ask about the launch")
        precondition(reopened.note(for: "ada@example.com", accountKey: scopeB) == "Separate workspace note")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600, "Private notes must only be readable by the file owner")
        try reopened.save("", for: "ada@example.com", accountKey: scopeA)
        precondition(MailContactNotesStore(fileURL: url).note(for: "ada@example.com", accountKey: scopeA).isEmpty)
        let corrupt = Data("invalid note storage".utf8)
        try corrupt.write(to: url)
        let broken = MailContactNotesStore(fileURL: url)
        precondition(broken.storageError != nil)
        do { try broken.save("Replacement", for: "ada@example.com", accountKey: scopeA); preconditionFailure("Corrupt notes must not be overwritten") } catch { }
        let preserved = try Data(contentsOf: url)
        precondition(preserved == corrupt)
        print("PASS: durable normalized private notes, workspace separation, owner-only permissions, deletion, and corruption protection")
    }

    @MainActor
    private static func websiteIcons(_ domains: WebsiteIconDomains) async throws {
        let suite = "PostmereWebsiteIcons-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let icons = MailRemoteParticipantImages(source: .websiteIcon, preferences: defaults,
                                                configuration: RealtimeFixtureProtocol.configuration(), iconDomains: domains)
        let recorder = RealtimeFixtureRecorder()
        RealtimeFixtureProtocol.recorder = recorder
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNg9HMDIgYIBQAPRgJV0G6wuQAAAABJRU5ErkJggg==")!
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(200, headers: ["Content-Type": "image/png"], chunks: [png]) }
        let privatePhoto = await icons.photo(email: "fixture@outlook.com")
        let invalidPhoto = await icons.photo(email: "fixture@local.test")
        let path = await icons.photo(email: "fixture@stripe.com/secret")
        let embedded = await icons.photo(email: "fixture@stripe.com?mail=person@private.org")
        try realtimeCheck(icons.enabled && privatePhoto == nil && invalidPhoto == nil && path == nil && embedded == nil &&
                          recorder.requests.isEmpty,
                          "Website lookup should default on but skip private and common personal mail domains")
        async let first = icons.photo(email: "special-id@scheduled.unique-id.newshop.co.uk")
        async let second = icons.photo(email: "different-person@support.newshop.co.uk")
        let (row, profile) = await (first, second)
        let request = recorder.requests.first!
        try realtimeCheck(recorder.requests.count == 1 && row?.image.width == 2 && profile?.website == "newshop.co.uk" &&
                          request.url?.absoluteString == "https://icons.bitwarden.net/newshop.co.uk/icon.png",
                          "An uncatalogued domain must resolve once without any address or sender subdomain disclosure")
        try realtimeCheck(["Cookie", "Authorization", "X-Ambient", "Referer"].allSatisfy { request.value(forHTTPHeaderField: $0) == nil },
                          "Website icon request included credentials or metadata")
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(404, headers: ["Content-Type": "image/png"], chunks: [png]) }
        let missing = await icons.photo(email: "fixture@metalwork.co.uk")
        _ = await icons.photo(email: "two@news.metalwork.co.uk")
        try realtimeCheck(missing == nil && recorder.requests.count == 2, "Missing website icons must be negative-cached")
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(302, headers: ["Location": "https://other.invalid/icon.png"]) }
        let redirected = await icons.photo(email: "fixture@builders.co.uk")
        try realtimeCheck(redirected == nil && recorder.requests.count == 3, "Icon redirect should produce initials")
        // This ICO holds a 16px and a 32px square in one directory.
        let ico = Data(base64Encoded: "AAABAAIAEBAAAAAAIABeAAAAJgAAACAgAAAAACAAcAAAAIQAAACJUE5HDQoaCgAAAA1JSERSAAAAEAAAABAIBgAAAB/z/2EAAAAlSURBVHicY7wjF/WfgQLARInmUQMggImBQsA0agDDqAEMlBsAALClAnN+lGHzAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAN0lEQVR4nO3QQREAMAgDQYoQhKG9XspUBZ+NgcvsudUvFpebcQcIECBAgAABAgQIECBAgACBTzCKpwKTBY+kSgAAAABJRU5ErkJggg==")!
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(200, headers: ["Content-Type": "image/x-icon"], chunks: [ico]) }
        let favicon = await icons.photo(email: "fixture@bitmap.co.uk")
        try realtimeCheck(favicon?.image.width == 32 && favicon?.image.height == 32 && recorder.requests.count == 4,
                          "An ICO site icon should use its largest valid representation")
        let reused = icons.cachedPhoto(email: "other@news.bitmap.co.uk")
        try realtimeCheck(reused?.image.width == 32 && reused?.website == "bitmap.co.uk" && recorder.requests.count == 4,
                          "Recycled rows draw a cached website icon on their first frame without a lookup")
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(404, headers: ["Content-Type": "image/x-icon"], chunks: [ico]) }
        let genericMissingIcon = await icons.photo(email: "fixture@nousericon.co.uk")
        try realtimeCheck(genericMissingIcon == nil, "A 404 containing an ICO must still fall back to initials")
        icons.enabled = false
        let disabled = await icons.photo(email: "again@newshop.co.uk")
        try realtimeCheck(disabled == nil && icons.cachedPhoto(email: "again@newshop.co.uk") == nil && recorder.requests.count == 5 &&
                          !MailRemoteParticipantImages(source: .websiteIcon, preferences: defaults).enabled,
                          "Disabling website icons should suppress cached images and persist across launches")
        defaults.removeObject(forKey: "showParticipantWebsiteIcons")
        defaults.set(false, forKey: "loadRemoteMailImagesAutomatically")
        let upgraded = MailRemoteParticipantImages(source: .websiteIcon, preferences: defaults)
        try realtimeCheck(!upgraded.enabled, "Upgrades must preserve an existing remote-content opt-out")
        upgraded.enabled = true
        try realtimeCheck(MailRemoteParticipantImages(source: .websiteIcon, preferences: defaults).enabled,
                          "The website preference should work independently after migration")
        print("PASS: real website icon flow over isolated fixture HTTP, one request per organization, misses, privacy control")
    }

    @MainActor
    private static func gravatarPhotos() async throws {
        let suite = "PostmereSenderPhotos-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let photos = MailRemoteParticipantImages(source: .gravatar, preferences: defaults, configuration: RealtimeFixtureProtocol.configuration())
        let recorder = RealtimeFixtureRecorder()
        RealtimeFixtureProtocol.recorder = recorder
        let (arrivals, continuation) = AsyncStream.makeStream(of: RealtimeFixtureProtocol.self)
        defer { continuation.finish() }
        RealtimeFixtureProtocol.handler = { _, fixture in continuation.yield(fixture) }
        let address = "fixture@example.test"
        let off = await photos.photo(email: address)
        try realtimeCheck(off == nil && recorder.requests.isEmpty, "Disabled lookups must send zero requests")
        photos.enabled = true
        try realtimeCheck(MailRemoteParticipantImages(source: .gravatar, preferences: defaults).enabled, "Explicit photo preference did not survive restart")
        var events = arrivals.makeAsyncIterator()
        let first = Task { await photos.photo(email: " FIXTURE@Example.Test ") }
        let second = Task { await photos.photo(email: address) }
        let response = await events.next()!
        let request = recorder.requests[0]
        let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let hash = "715bfed2a3994e3624c5dbb39b733e19ff11fdf5395fee9ac3218197d512d3c2"
        try realtimeCheck(url.scheme == "https" && url.host == "gravatar.com" && url.path == "/avatar/\(hash)" &&
                          url.queryItems?.contains(URLQueryItem(name: "d", value: "404")) == true,
                          "Photo requests must use the normalized SHA-256 Gravatar URL")
        try realtimeCheck(["Cookie", "Authorization", "X-Ambient"].allSatisfy { request.value(forHTTPHeaderField: $0) == nil },
                          "Photo request included ambient credentials or headers")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNg9HMDIgYIBQAPRgJV0G6wuQAAAABJRU5ErkJggg==")!
        response.response(200, headers: ["Content-Type": "image/png"], chunks: [png])
        let a = await first.value, b = await second.value, cached = await photos.photo(email: address)
        try realtimeCheck(a?.image.width == 2 && b?.image.width == 2 && cached?.image.width == 2 && recorder.requests.count == 1,
                          "Concurrent row/profile requests must share one valid cached image")

        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(404) }
        let missing = await photos.photo(email: "missing@example.test")
        _ = await photos.photo(email: "missing@example.test")
        try realtimeCheck(missing == nil && recorder.requests.count == 2, "Missing Gravatars should fall back and be negative-cached")
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.response(200, headers: ["Content-Type": "image/png"], chunks: [Data("not an image".utf8)]) }
        let invalid = await photos.photo(email: "invalid@example.test")
        try realtimeCheck(invalid == nil, "A non-image response was displayed")
        RealtimeFixtureProtocol.handler = { _, fixture in fixture.client?.urlProtocol(fixture, didFailWithError: URLError(.notConnectedToInternet)) }
        let offline = await photos.photo(email: "offline@example.test")
        try realtimeCheck(offline == nil, "A connection failure must leave the local fallback visible")

        RealtimeFixtureProtocol.handler = { _, _ in }
        let count = recorder.requests.count
        let outstanding = Task { await photos.photo(email: "pending@example.test") }
        try await eventually("Outstanding photo lookup never started") { recorder.requests.count > count }
        photos.enabled = false
        let cancelled = await outstanding.value
        let previous = await photos.photo(email: address)
        try realtimeCheck(cancelled == nil && previous == nil, "Disabling Gravatar must cancel in-flight requests and hide cached images")
        print("PASS: opt-in only, hashed HTTPS URL, shared cache, missing and invalid images, network failure and opt-out")
    }
}
