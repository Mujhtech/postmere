import Foundation

/// One per open composer. Keystrokes and recipient fields share the same account's contact history.
actor MailRecipientLookup {
    nonisolated struct Source: Equatable, Sendable {
        let revision: Int
        let accountKey: String
    }

    private var directory: (source: Source, contacts: MailRecipientSuggestions)?

    func matches(_ input: String, source: Source, messages: [MailMessage],
                 ownAddresses: [String]) -> [MailRecipientSuggestion] {
        guard !Task.isCancelled else { return [] }
        if directory?.source != source {
            directory = (source, MailRecipientSuggestions(messages: messages, accountKey: source.accountKey))
        }
        guard !Task.isCancelled, let directory else { return [] }
        return directory.contacts.suggestions(for: input, excluding: MailRecipientSuggestions.completedAddresses(in: input),
                                              ownAddresses: ownAddresses, limit: 4)
    }
}

extension MailStore {
    var draftContactAccountKey: String {
        MailContactIdentity.accountKey(account: draftAccount.rawValue, providerAccountEmail: draftProviderAccountEmail)
    }

    var draftRecipientSource: MailRecipientLookup.Source? {
        guard searchableAccounts.contains(draftAccount.rawValue) else { return nil }
        return .init(revision: mailboxDataRevision, accountKey: draftContactAccountKey)
    }

    func senderContext(email: String, accountKey: String) -> MailSenderContext {
        MailSenderContext.build(email: email, accountKey: accountKey, messages: messages.filter(isAccountVisible))
    }

    func recipientSuggestions(for input: String, excluding: [String] = [], accountKey: String? = nil) -> [MailRecipientSuggestion] {
        MailRecipientSuggestions(messages: messages.filter(isAccountVisible), accountKey: accountKey ?? draftContactAccountKey)
            .suggestions(for: input, excluding: excluding, ownAddresses: MailAccount.allCases.map(\.email))
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
