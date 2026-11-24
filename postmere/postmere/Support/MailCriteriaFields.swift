import SwiftUI

/// The same criteria controls are used by saved views and inbox tabs.
struct MailCriteriaFields: View {
    @Binding var criteria: SavedInboxCriteria
    var showsMailbox = true

    var body: some View {
        Section {
            TextField("Search rule", text: $criteria.query, prompt: Text("from:alex has:attachment"))
            Picker("Search plain text in", selection: $criteria.searchField) {
                ForEach(MailSearchField.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Match")
        } footer: {
            let issues = MailSearchQuery(source: criteria.query, defaultField: criteria.searchField).issues
            Group {
                if let issue = issues.first {
                    Text(issue.message).foregroundStyle(.red)
                } else {
                    Text("Combine conditions with spaces. Use OR for alternatives and a minus sign to exclude one.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        Section("From") {
            if showsMailbox {
                Picker("Mailbox", selection: $criteria.mailbox) {
                    Text("All mailboxes").tag(nil as Mailbox?)
                    ForEach(Mailbox.allCases) { Text($0.title).tag(Optional($0)) }
                }
            }
            Picker("Account", selection: $criteria.account) {
                Text("All accounts").tag(nil as String?)
                ForEach(MailAccount.allCases) { Text($0.name).tag(Optional($0.rawValue)) }
            }
            TextField("Sender contains", text: $criteria.sender)
            TextField("Sender domain", text: $criteria.domain, prompt: Text("example.com"))
        }
        Section("Only show") {
            Toggle("Unread", isOn: $criteria.unreadOnly)
            Toggle("With attachments", isOn: $criteria.attachmentsOnly)
            Toggle("Starred", isOn: $criteria.starredOnly)
        }
    }
}
