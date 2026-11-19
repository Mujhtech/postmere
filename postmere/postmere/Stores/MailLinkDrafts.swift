import Foundation
import Observation

struct MailLinkDraft {
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body: String?

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "mailto", parts.host == nil, parts.fragment == nil,
              let address = parts.percentEncodedPath.removingPercentEncoding else { return nil }
        var recipients = ["to": [address], "cc": [], "bcc": []]
        var seen = Set<String>()
        for item in parts.percentEncodedQueryItems ?? [] {
            guard let key = item.name.removingPercentEncoding?.lowercased() else { return nil }
            guard ["to", "cc", "bcc", "subject", "body"].contains(key) else { continue }
            guard let value = (item.value ?? "").removingPercentEncoding else { return nil }
            if key == "body" {
                let controls = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\r\n\t"))
                guard seen.insert(key).inserted, value.rangeOfCharacter(from: controls) == nil else { return nil }
                body = value.replacingOccurrences(of: "\r\n", with: "\n")
            } else if key == "subject" {
                guard seen.insert(key).inserted, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
                subject = value
            } else {
                recipients[key, default: []].append(value)
            }
        }
        func addresses(_ key: String) -> String? {
            let input = recipients[key, default: []].joined(separator: ",")
            guard input.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            let list = MailAddressList(input)
            guard list.invalid.isEmpty else { return nil }
            return list.addresses.joined(separator: ", ")
        }
        guard let to = addresses("to"), let cc = addresses("cc"), let bcc = addresses("bcc") else { return nil }
        self.to = to
        self.cc = cc
        self.bcc = bcc
    }
}

/// Hold links in memory while setup, account loading or an existing draft owns the window.
@MainActor @Observable
final class MailLinkDrafts {
    private var waiting: [MailLinkDraft] = []
    private var workspace: String?
    var hasPending: Bool { !waiting.isEmpty }

    func useWorkspace(_ verifiedScope: String?) {
        if let workspace, workspace != verifiedScope { waiting.removeAll() }
        workspace = verifiedScope
    }

    @discardableResult
    func receive(_ url: URL, verifiedScope: String?) -> Bool {
        guard let draft = MailLinkDraft(url: url) else { return false }
        useWorkspace(verifiedScope)
        waiting.append(draft)
        return true
    }

    func canOpen(in store: MailStore, verifiedScope: String?) -> Bool {
        hasPending && verifiedScope != nil && workspace == verifiedScope
            && !store.isOpeningMailbox && !store.isComposing && !store.draftRecoveryAvailable
            && MailAccount.sendingAccounts.contains { $0.remote?.scope == verifiedScope }
    }

    @discardableResult
    func openNext(in store: MailStore, verifiedScope: String?) -> Bool {
        guard canOpen(in: store, verifiedScope: verifiedScope), let draft = waiting.first,
              store.beginCompose(from: draft, verifiedScope: verifiedScope) else { return false }
        waiting.removeFirst()
        return true
    }

    func dismissNext() {
        if hasPending { waiting.removeFirst() }
    }
}
