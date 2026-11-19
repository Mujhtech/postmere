import SwiftUI
import AppKit

struct AttachmentLibraryView: View {
    @Bindable var store: MailStore
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var account: String?
    @State private var preview: MailAttachment?
    @State private var loadingID: UUID?
    @State private var error: String?

    private struct Entry: Identifiable {
        var id: UUID { attachment.id }
        let attachment: MailAttachment
        let message: MailMessage
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var entries: [Entry] {
        var seen: Set<UUID> = []
        let query = self.query
        return store.messages.filter { store.isAccountVisible($0) && $0.mailbox != .trash && (account == nil || $0.account == account) }
            .flatMap { message in message.attachments.map { Entry(attachment: $0, message: message) } }
            .filter { entry in
                (query.isEmpty || [entry.attachment.name, entry.message.sender, entry.message.subject].contains { $0.localizedStandardContains(query) })
                    && seen.insert(entry.id).inserted
            }
    }

    var body: some View {
        let entries = self.entries
        VStack(spacing: 0) {
            PostmereSheetHeader("Attachments")
            HStack {
                TextField("Search files, senders, and subjects", text: $search).textFieldStyle(.roundedBorder)
                Picker("Account", selection: $account) {
                    Text("All accounts").tag(nil as String?)
                    ForEach(MailAccount.allCases) { Text($0.name).tag(Optional($0.rawValue)) }
                }.frame(width: 180).labelsHidden()
            }.padding(.horizontal, 24).padding(.bottom, 14)
            Divider()
            if entries.isEmpty && !query.isEmpty {
                PostmereSearchEmptyState(query: query) { search = "" }
            } else if entries.isEmpty {
                ContentUnavailableView {
                    PostmereLabel.emptyState(account == nil ? "No attachments" : "No attachments in this account", symbol: "paperclip", size: 40)
                } description: {
                    Text("Files from your messages will appear here.")
                } actions: {
                    if account != nil {
                        Button("Show All Accounts") { account = nil }
                    }
                }
            } else {
                List(entries) { entry in
                    HStack(spacing: 12) {
                        AttachmentIconView(attachment: entry.attachment, size: 40)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.attachment.name).fontWeight(.medium).lineLimit(1)
                            Text("\(entry.message.sender) · \(entry.message.displaySubject)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(entry.attachment.localURL == nil && entry.attachment.providerAttachmentID == nil ? "Sample · no file included" : entry.attachment.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if loadingID == entry.id { ProgressView().controlSize(.small) }
                        else {
                            Button("Preview") { resolve(entry, save: false) }
                                .disabled(entry.attachment.localURL == nil && entry.attachment.providerAttachmentID == nil)
                            Button { resolve(entry, save: true) } label: { PostmereIcon("arrow.down.to.line", size: 16).foregroundStyle(PostmereTheme.icon) }
                                .help("Save attachment").accessibilityLabel("Save \(entry.attachment.name)")
                                .disabled(entry.attachment.localURL == nil && entry.attachment.providerAttachmentID == nil)
                        }
                        Button {
                            runtime.openMessage(entry.message.id)
                            dismiss()
                        } label: { PostmereIcon("arrow.up.forward.square", size: 16).foregroundStyle(PostmereTheme.icon) }
                            .help("Open message").accessibilityLabel("Open message for \(entry.attachment.name)")
                    }.padding(.vertical, 7).controlSize(.small)
                }.listStyle(.inset)
            }
        }.frame(width: 720, height: 510)
            .sheet(item: $preview) { AttachmentPreviewSheet(attachment: $0) }
            .alert("Couldn’t open attachment", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func resolve(_ entry: Entry, save: Bool) {
        loadingID = entry.id
        Task {
            defer { loadingID = nil }
            do {
                let resolved = try await runtime.resolveAttachment(entry.attachment, in: entry.message)
                if save { saveAttachment(resolved) } else { preview = resolved }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func saveAttachment(_ attachment: MailAttachment) {
        guard let source = attachment.localURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do { try Data(contentsOf: source).write(to: destination, options: .atomic) }
            catch { self.error = error.localizedDescription }
        }
    }
}
