import Foundation

@main
private struct SenderContextChecks {
    @MainActor
    static func main() throws {
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

        precondition(store.setSenderVIP(true, email: "ADA@example.com", accountKey: scopeA))
        precondition(store.hasSenderVIP(email: "ada@example.com", accountKey: scopeA))
        precondition(!store.hasSenderVIP(email: "ada@example.com", accountKey: scopeB))
        precondition(store.setSenderVIP(false, email: "ada@example.com", accountKey: scopeA))
        precondition(!store.hasSenderVIP(email: "ada@example.com", accountKey: scopeA))
        RemoteAccountRegistry.accounts = [accountB]
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
}
