import Foundation

extension MailStore {
    /// Workspace signatures use the full server/user/account identity.
    var draftSignatureAccountKey: String {
        if draftAccount.isRemote { return draftAccount.rawValue }
        let providerEmail = draftProviderAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !providerEmail.isEmpty { return providerEmail.lowercased() }
        let email = draftAccount.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? draftAccount.rawValue : email.lowercased()
    }

    func initialSignatureBody(context: MailSignatureContext, quotedText: String? = nil) -> MailSignatureBody {
        MailSignatureStore.shared.initialBody(for: draftSignatureAccountKey, context: context, quotedText: quotedText)
    }
}
