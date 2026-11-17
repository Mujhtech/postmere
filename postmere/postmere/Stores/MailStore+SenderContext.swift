import Foundation

extension MailStore {
    var draftContactAccountKey: String {
        MailContactIdentity.accountKey(account: draftAccount.rawValue, providerAccountEmail: draftProviderAccountEmail)
    }

    func senderContext(email: String, accountKey: String) -> MailSenderContext {
        MailSenderContext.build(email: email, accountKey: accountKey, messages: messages.filter(isAccountVisible))
    }

    func recipientSuggestions(for input: String, excluding: [String] = [], accountKey: String? = nil) -> [MailRecipientSuggestion] {
        MailRecipientSuggestions.suggestions(for: input, messages: messages.filter(isAccountVisible), accountKey: accountKey ?? draftContactAccountKey,
            excluding: excluding, ownAddresses: MailAccount.allCases.map(\.email))
    }

    func hasSenderVIP(email: String, accountKey: String) -> Bool {
        guard let scope = MailContactIdentity.scope(from: accountKey) else { return false }
        let email = MailContactIdentity.email(email)
        return vipContacts.contains { $0.kind == .person && $0.normalizedValue == email && $0.account == scope.account
            && $0.providerAccountEmail?.lowercased() == scope.providerEmail }
    }

    @discardableResult
    func setSenderVIP(_ enabled: Bool, email: String, accountKey: String) -> Bool {
        guard let scope = MailContactIdentity.scope(from: accountKey) else { return false }
        let email = MailContactIdentity.email(email)
        if enabled {
            return saveVIPContact(VIPContact(value: email, kind: .person, account: scope.account, providerAccountEmail: scope.providerEmail))
        }
        let ids = vipContacts.filter { $0.kind == .person && $0.normalizedValue == email && $0.account == scope.account
            && $0.providerAccountEmail?.lowercased() == scope.providerEmail }.map(\.id)
        for id in ids { deleteVIPContact(id) }
        return true
    }
}
