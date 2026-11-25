import QuickLook
import SwiftUI

// MARK: - Files

/// Every attachment in your mail, newest first, searchable by file, sender or subject.
struct MobileFilesScreen: View {
    let runtime: MailRuntime
    var onOpen: (MailMessage) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var kind: Kind = .all
    @State private var loading: UUID?
    @State private var preview: URL?
    @State private var error: String?

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", documents = "Docs", images = "Images", other = "Other"
        var id: String { rawValue }

        func matches(_ name: String) -> Bool {
            let ext = (name as NSString).pathExtension.lowercased()
            let images: Set = ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp"]
            let documents: Set = ["pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "key", "pages", "numbers", "txt", "rtf", "md"]
            switch self {
            case .all: return true
            case .images: return images.contains(ext)
            case .documents: return documents.contains(ext)
            case .other: return !images.contains(ext) && !documents.contains(ext)
            }
        }
    }

    private struct Entry: Identifiable {
        var id: UUID { attachment.id }
        let attachment: MailAttachment
        let message: MailMessage
        var available: Bool { attachment.localURL != nil || attachment.providerAttachmentID != nil }
    }

    private var entries: [Entry] {
        let store = runtime.store
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<UUID> = []
        return store.messages
            .filter { store.isAccountVisible($0) && !$0.mailbox.isJunkOrTrash && !$0.attachments.isEmpty }
            .sorted { $0.sentAt > $1.sentAt }
            .flatMap { message in message.attachments.map { Entry(attachment: $0, message: message) } }
            .filter { entry in
                kind.matches(entry.attachment.name)
                    && (query.isEmpty || [entry.attachment.name, entry.message.sender, entry.message.subject]
                        .contains { $0.localizedStandardContains(query) })
                    && seen.insert(entry.id).inserted
            }
    }

    var body: some View {
        let entries = self.entries
        List {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            }
            ForEach(entries) { entry in
                Button { open(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
                    .disabled(!entry.available || loading != nil)
                    .swipeActions {
                        Button("Message", systemImage: "envelope") { onOpen(entry.message) }.tint(.blue)
                    }
                    .contextMenu {
                        Button("Preview", systemImage: "eye") { open(entry) }.disabled(!entry.available)
                        Button("Open Message", systemImage: "envelope") { onOpen(entry.message) }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if entries.isEmpty {
                if search.isEmpty {
                    MobileEmptyState(symbol: "paperclip", title: kind == .all ? "No files" : "No \(kind.rawValue.lowercased())",
                                     message: "Files people send you appear here.")
                } else {
                    MobileEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try a file name or a sender.")
                }
            }
        }
        .searchable(text: $search, prompt: "Files, senders, subjects")
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .alert("Couldn’t open the file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: MobileFileIcon.symbol(for: entry.attachment.name))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MobileFileIcon.tint(for: entry.attachment.name))
                .frame(width: 40, height: 40)
                .background(MobileFileIcon.tint(for: entry.attachment.name).opacity(0.13),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.attachment.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.message.sender) · \(entry.message.sentAt.mobileListDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !entry.attachment.detail.isEmpty {
                    Text(entry.attachment.detail).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            if loading == entry.id { ProgressView() }
        }
        .contentShape(Rectangle())
        .opacity(entry.available ? 1 : 0.5)
    }

    private func open(_ entry: Entry) {
        loading = entry.id
        Task {
            defer { loading = nil }
            do {
                preview = try await runtime.resolveAttachment(entry.attachment, in: entry.message).localURL
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum MobileFileIcon {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext.fill"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp": "photo.fill"
        case "mov", "mp4", "m4v": "film.fill"
        case "zip", "gz", "tar", "rar", "7z": "doc.zipper"
        case "ics": "calendar"
        case "xls", "xlsx", "csv", "numbers": "tablecells.fill"
        case "ppt", "pptx", "key": "rectangle.on.rectangle.angled.fill"
        case "mp3", "m4a", "wav", "aac": "waveform"
        default: "doc.fill"
        }
    }

    static func tint(for name: String) -> Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": .red
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp": .teal
        case "mov", "mp4", "m4v": .purple
        case "xls", "xlsx", "csv", "numbers": .green
        case "ppt", "pptx", "key": .orange
        case "doc", "docx", "pages", "txt", "rtf", "md": .blue
        default: .gray
        }
    }
}

// MARK: - Online search

/// Searches the provider's whole mailbox, including mail older than what's on this phone.
struct MobileOnlineSearchSheet: View {
    let runtime: MailRuntime
    var initialQuery = ""
    var onOpen: (MailMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: UUID?
    @State private var query = ""
    @State private var results: [MailMessage] = []
    @State private var cursor: String?
    @State private var hasMore = false
    @State private var busy = false
    @State private var searched = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var account: BackendAccount? { runtime.backend.accounts.first { $0.id == accountID } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search all of your mail", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await search(more: false) } }
                        if busy && results.isEmpty { ProgressView() }
                    }
                    if runtime.backend.accounts.count > 1 {
                        Picker("Account", selection: $accountID) {
                            ForEach(runtime.backend.accounts) { account in
                                Text(account.email).tag(Optional(account.id))
                            }
                        }
                    }
                } footer: {
                    Text("Searches \(Brand.providerName(account?.provider) ?? "your provider") directly, using its search syntax, so older mail shows up too.")
                }
                .mobileSheetRows()
                if let error {
                    Section { Text(error).foregroundStyle(PostmereTheme.destructiveInk) }
                    .mobileSheetRows()
                }
                if !results.isEmpty {
                    Section("\(results.count)\(hasMore ? "+" : "") results") {
                        ForEach(results) { message in
                            Button {
                                dismiss()
                                onOpen(message)
                            } label: {
                                MobileMessageRow(message: message, conversationCount: 1, showsMailbox: true)
                            }
                            .buttonStyle(.plain)
                        }
                        if hasMore {
                            Button {
                                Task { await search(more: true) }
                            } label: {
                                HStack { Text("Load older results"); if busy { Spacer(); ProgressView() } }
                            }
                            .disabled(busy)
                        }
                    }
                    .mobileSheetRows()
                } else if searched && !busy {
                    Section {
                        Text("Nothing found. Try different words.").foregroundStyle(.secondary)
                    }
                    .mobileSheetRows()
                }
            }
            .navigationTitle("Search Online")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search", systemImage: "magnifyingglass") { Task { await search(more: false) } }
                        .disabled(busy || accountID == nil || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                query = initialQuery
                accountID = runtime.store.selectedAccount.flatMap { MailAccount(rawValue: $0) }?.remote?.accountID
                    ?? runtime.backend.accounts.first?.id
                if query.isEmpty { focused = true } else { Task { await search(more: false) } }
            }
            .onChange(of: accountID) { results = []; cursor = nil; hasMore = false; searched = false }
        }
        .mobileSheetSurface()
    }

    private func search(more: Bool) async {
        guard !busy, let sessionID = runtime.backend.realtimeGeneration, let accountID,
              let identity = RemoteAccountRegistry.accounts.first(where: { $0.accountID == accountID }) else { return }
        let captured = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { return }
        busy = true
        error = nil
        focused = false
        defer { busy = false }
        let store = runtime.store
        do {
            let read = store.beginProviderPage(for: identity.localID)
            defer { store.endProviderPage(read) }
            let page: BackendMailPage = try await runtime.backend.request(
                "POST", "/v1/mail/accounts/\(accountID.uuidString)/search",
                body: BackendSearchRequest(query: captured, limit: 50, cursor: more ? cursor : nil))
            let incoming = try await page.localMessages(for: identity)
            func isCurrent() -> Bool {
                self.accountID == accountID && runtime.backend.realtimeGeneration == sessionID
                    && runtime.backend.isAccountConnected(accountID, scope: identity.scope)
            }
            guard await store.mergeReceivedPage(incoming, read: read, isCurrent: isCurrent), isCurrent() else { return }
            // The store may keep its own copy of a message under another ID; show that one.
            let hits = (more ? results : []) + incoming
            let ids = Set(hits.compactMap(\.backendMessageID))
            var stored: [UUID: MailMessage] = [:]
            for row in store.messages where row.account == identity.localID && !row.isDeletedOnProvider {
                if let id = row.backendMessageID, ids.contains(id) { stored[id] = row }
            }
            withAnimation(.snappy) {
                results = hits.compactMap { hit in hit.backendMessageID.flatMap { stored.removeValue(forKey: $0) } }
            }
            cursor = page.nextCursor
            hasMore = page.hasMore
            searched = true
        } catch {
            if self.accountID == accountID { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Save search as a view

/// Names the current search so it sits under Views in the mailbox list.
struct MobileSaveViewSheet: View {
    let store: MailStore
    /// A saved view to change, instead of saving the current search.
    var editing: SavedInboxView?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var criteria = SavedInboxCriteria()
    @State private var matches: Int?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).focused($focused).submitLabel(.done).onSubmit(save)
                }
                .mobileSheetRows()
                Section {
                    TextField("Search rule", text: $criteria.query, prompt: Text("from:alex has:attachment"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Unread only", isOn: $criteria.unreadOnly)
                    Toggle("Starred only", isOn: $criteria.starredOnly)
                    Toggle("With attachments", isOn: $criteria.attachmentsOnly)
                    TextField("From sender", text: $criteria.sender)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("From domain", text: $criteria.domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Shows mail that matches")
                } footer: {
                    if let matches { Text("\(matches) message\(matches == 1 ? "" : "s") match right now.") }
                }
                .mobileSheetRows()
            }
            .navigationTitle(editing == nil ? "Save as View" : "Edit View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let editing {
                    criteria = editing.criteria
                    name = editing.name
                    return
                }
                criteria = SavedInboxCriteria(query: store.searchText, account: store.selectedAccount,
                                              unreadOnly: store.unreadOnly, attachmentsOnly: store.attachmentsOnly,
                                              mailbox: store.searchScope == .allMailboxes ? nil : store.selectedMailbox)
                criteria.searchField = store.searchField
                name = store.searchText.trimmingCharacters(in: .whitespaces).capitalized
                focused = true
            }
            .task(id: criteria) {
                try? await Task.sleep(for: .milliseconds(250))
                matches = store.messages.count { store.matchesSavedView($0, criteria: criteria) }
            }
        }
        .mobileSheetDetents()
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if var editing {
            editing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            editing.criteria = criteria
            store.saveInboxView(editing)
            dismiss()
            return
        }
        let view = store.saveInboxView(name: name, criteria: criteria)
        store.endSearch()
        store.selectSavedView(view)
        dismiss()
    }
}
