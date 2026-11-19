import AppKit

@main
private struct SignatureChecks {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let suite = "Postmere-Signature-Checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Legacy signature", forKey: "signatureText")
        let preferences = MailSignatureStore(defaults: defaults)
        precondition(preferences.signature(for: "one@example.com").text == "Legacy signature")
        precondition(preferences.signature(for: "provider:Opaque/User42").text == "Legacy signature")
        precondition(defaults.data(forKey: MailSignatureStore.storageKey) == nil, "Reading a legacy signature must not rewrite saved preferences")

        let rich = NSAttributedString(string: "Ada Lovelace\nPostmere", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let custom = MailSignature(text: rich.string, rtfData: MailTemplate.encodeRTF(rich), includeInReplies: false)
        try preferences.save(custom, for: " ADA@EXAMPLE.COM ")
        precondition(preferences.signature(for: "ada@example.com") == custom)
        precondition(preferences.signature(for: "other@example.com").text == "Legacy signature", "Customizing one account must not change another")
        try preferences.save(MailSignature(text: "Opaque ID signature"), for: "provider:Opaque/User42")
        precondition(preferences.signature(for: "provider:Opaque/User42").text == "Opaque ID signature")
        precondition(preferences.signature(for: "provider:opaque/user42").text == "Legacy signature", "Opaque account IDs must preserve case")
        let reloaded = MailSignatureStore(defaults: defaults)
        precondition(reloaded.signature(for: "ADA@example.com") == custom, "Rich account signatures and flags must survive reload")
        try reloaded.save(MailSignature(text: ""), for: "other@example.com")
        precondition(reloaded.hasCustomSignature(for: "other@example.com") && reloaded.signature(for: "other@example.com").text.isEmpty,
                     "An explicitly blank account signature must suppress the legacy default")
        print("PASS: legacy fallback, isolated email/opaque account keys, durable rich preferences, and explicit blank signatures")

        let newBody = reloaded.initialBody(for: "ada@example.com", context: .newMessage)
        precondition(newBody.text == "\n\n" + custom.text)
        let newRich = MailTemplate.richBody(text: newBody.text, rtf: newBody.rtfData)
        let font = newRich.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        precondition(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "Initial composition must retain signature formatting")
        let linked = newBody.prepending("Email link body")
        let linkedRich = MailTemplate.richBody(text: linked.text, rtf: linked.rtfData)
        let signatureStart = ("Email link body\n\n" as NSString).length
        let linkedFont = linkedRich.attribute(.font, at: signatureStart, effectiveRange: nil) as! NSFont
        precondition(linked.text == "Email link body\n\n" + custom.text
                     && NSFontManager.shared.traits(of: linkedFont).contains(.boldFontMask),
                     "Email link text should precede the original formatted account signature")
        let quoted = "On Tuesday, 👩🏽‍💻 Ada wrote:\n> Original message"
        let reply = reloaded.initialBody(for: "ada@example.com", context: .reply, quotedText: quoted)
        precondition(reply.text == "\n\n" + quoted, "Disabled reply signatures must preserve the full quote")
        let forward = reloaded.initialBody(for: "ada@example.com", context: .forward, quotedText: quoted)
        precondition(forward.text == "\n\n" + custom.text + "\n\n" + quoted)
        let defaultsFromOldProfile = try JSONDecoder().decode(MailSignature.self, from: Data("{\"text\":\"Old profile\"}".utf8))
        precondition(MailSignatureContext.allCases.allSatisfy { defaultsFromOldProfile.applies(to: $0) })
        print("PASS: context preferences, rich initial body, exact quoted text, and backward-compatible flags")

        let corrupt = Data("not valid JSON".utf8)
        defaults.set(corrupt, forKey: MailSignatureStore.storageKey)
        let broken = MailSignatureStore(defaults: defaults)
        precondition(broken.loadError != nil)
        do {
            try broken.save(MailSignature(text: "Replacement"), for: "ada@example.com")
            preconditionFailure("Corrupt saved signatures must block overwrite")
        } catch { }
        precondition(defaults.data(forKey: MailSignatureStore.storageKey) == corrupt)
        print("PASS: unreadable preferences preserve original bytes and block replacement")
    }
}
