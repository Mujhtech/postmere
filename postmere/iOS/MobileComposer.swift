import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer over the shared draft in `MailStore`: recipients with suggestions,
/// subject, body, and a tools bar for attachments, snippets, AI and scheduling.
struct MobileComposer: View {
    let runtime: MailRuntime
    @Bindable var store: MailStore
    @Environment(\.postmereAccent) private var palette
    @Environment(MobilePresenter.self) private var presenter
    @State private var showsCopies = false
    @State private var confirmsClose = false
    @State private var importsFiles = false
    @State private var picksPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var attachmentError: String?
    @State private var tool: Tool?
    @State private var addsLink = false
    @State private var linkURL = ""
    @State private var selection: TextSelection?
    /// Set while sending so the formatted copy made for sending isn't cleared.
    @State private var sending = false
    @FocusState private var field: Field?

    private enum Field: Hashable { case to, cc, bcc, subject, body }

    private enum Tool: String, Identifiable {
        case snippets, writer, availability, booking
        var id: String { rawValue }
    }

    init(runtime: MailRuntime) {
        self.runtime = runtime
        self.store = runtime.store
    }

    private var canSend: Bool {
        store.canSendDraft && !store.draftTo.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if MailAccount.sendingAccounts.count > 1 || !store.draftAccount.isConnected {
                        fromRow
                        rule
                    }
                    addressRow("To", text: $store.draftTo, field: .to) {
                        if !showsCopies {
                            Button("Cc/Bcc") { showsCopies = true; field = .cc }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(Mobile.raised, in: Capsule())
                        }
                    }
                    suggestions(for: .to, text: $store.draftTo)
                    rule
                    if showsCopies {
                        addressRow("Cc", text: $store.draftCc, field: .cc) { EmptyView() }
                        suggestions(for: .cc, text: $store.draftCc)
                        rule
                        addressRow("Bcc", text: $store.draftBcc, field: .bcc) { EmptyView() }
                        suggestions(for: .bcc, text: $store.draftBcc)
                        rule
                    }
                    TextField("Subject", text: $store.draftSubject, axis: .vertical)
                        .font(.system(size: 18, weight: .semibold))
                        .focused($field, equals: .subject)
                        .submitLabel(.next)
                        .onSubmit { field = .body }
                        .padding(.horizontal, Mobile.gutter)
                        .padding(.vertical, 14)
                    rule
                    status
                    if !store.draftAttachments.isEmpty { attachments }
                    if let issue {
                        Label(issue, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(PostmereTheme.destructiveInk)
                            .padding(.horizontal, Mobile.gutter)
                            .padding(.top, 12)
                    }
                    TextEditor(text: $store.draftBody, selection: $selection)
                        .font(.system(size: 17))
                        .lineSpacing(4)
                        .focused($field, equals: .body)
                        .scrollDisabled(true)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 320)
                        .padding(.horizontal, Mobile.gutter - 5)
                        .padding(.vertical, 8)
                        .overlay(alignment: .topLeading) {
                            if store.draftBody.isEmpty {
                                Text("Write your message")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, Mobile.gutter)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Mobile.background)
            .safeAreaInset(edge: .bottom) { toolsBar }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        if store.hasUnsavedDraftChanges { confirmsClose = true } else { store.discardDraftChanges() }
                    }
                    .confirmationDialog("Keep this draft?", isPresented: $confirmsClose, titleVisibility: .visible) {
                        Button("Save Draft") { store.saveDraft() }
                        Button("Delete Draft", role: .destructive) { store.discardDraftChanges() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { sendButton }
            }
            .alert("Insert Link", isPresented: $addsLink) {
                TextField("https://example.com", text: $linkURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Insert") { insertLink() }
            } message: {
                Text("Select words first to turn them into the link.")
            }
            .fileImporter(isPresented: $importsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                attach { try store.addDraftAttachments(from: result.get()) }
            }
            .photosPicker(isPresented: $picksPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
            .onChange(of: photos) { importPhotos() }
            // The phone edits plain text. A rich copy from a signature or quote would
            // otherwise be sent as the HTML part without what was typed here.
            .onChange(of: store.draftBody) { if !sending, store.draftBodyRTF != nil { store.draftBodyRTF = nil } }
            .sheet(item: $tool) { tool in
                switch tool {
                case .snippets: MobileSnippetSheet(store: store)
                case .writer: MobileAIWriterSheet(runtime: runtime)
                case .availability: MobileAvailabilitySheet { insertBlock($0) }
                case .booking:
                    NavigationStack {
                        MobileBookingLinksScreen(session: runtime.backend) { insertBlock($0) }
                    }
                }
            }
            .task { field = store.draftTo.isEmpty ? .to : .body }
            // "Draft intro" from a sender's details opens straight into the AI writer.
            .onChange(of: store.pendingWriterPrompt, initial: true) {
                if store.pendingWriterPrompt != nil, runtime.backend.canAccessWorkspace, tool == nil { tool = .writer }
            }
            .onAppear { showsCopies = !store.draftCc.isEmpty || !store.draftBcc.isEmpty }
            .interactiveDismissDisabled()
        }
    }

    private var title: String {
        store.draftInReplyTo == nil ? "New message" : "Reply"
    }

    private var issue: String? {
        attachmentError ?? (store.draftTo.isEmpty ? nil : store.draftValidationMessage)
    }

    private var rule: some View {
        MobileHairline(leading: Mobile.gutter)
    }

    // MARK: Send

    private var sendButton: some View {
        Menu {
            Button("Send Later…", systemImage: "clock") { presenter.task = .sendLater }
            if store.draftSendAt != nil {
                Button("Send Now", systemImage: "paperplane") {
                    store.draftSendAt = nil
                    send()
                }
            }
        } label: {
            Label(store.draftSendAt == nil ? "Send" : "Schedule",
                  systemImage: store.draftSendAt == nil ? "arrow.up" : "clock")
                .fontWeight(.bold)
        } primaryAction: {
            send()
        }
        .buttonStyle(.glassProminent)
        .tint(palette.accent)
        .disabled(!canSend)
        .accessibilityHint("Touch and hold to send later")
    }

    /// Sends with any **bold**, *italic* and lists turned into real formatting.
    private func send() {
        sending = true
        if let rich = MobileMarkdown.rich(store.draftBody) {
            store.draftBody = rich.plain
            store.draftBodyRTF = rich.rtf
        }
        store.sendDraft()
        sending = false
    }

    /// Wraps the selection in a Markdown marker, or inserts an empty pair at the cursor.
    private func wrap(_ marker: String) {
        var text = store.draftBody
        if case .selection(let range)? = selection?.indices, range.lowerBound >= text.startIndex,
           range.upperBound <= text.endIndex {
            let selected = text[range]
            text.replaceSubrange(range, with: marker + selected + marker)
        } else {
            text += marker + marker
        }
        selection = nil
        store.draftBody = text
    }

    /// Turns the selected words into a link, or adds the address itself.
    private func insertLink() {
        let url = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host != nil else { return }
        var text = store.draftBody
        if case .selection(let range)? = selection?.indices, range.lowerBound >= text.startIndex,
           range.upperBound <= text.endIndex, !text[range].isEmpty {
            text.replaceSubrange(range, with: "[\(text[range])](\(url))")
        } else {
            text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + "[\(parsed.host ?? url)](\(url))"
        }
        selection = nil
        store.draftBody = text
    }

    /// Starts the current line as a list item.
    private func bullet() {
        var text = store.draftBody
        var position = text.endIndex
        if case .selection(let range)? = selection?.indices, range.lowerBound <= text.endIndex { position = range.lowerBound }
        let lineStart = text[..<position].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        if text[lineStart...].hasPrefix("- ") {
            text.removeSubrange(lineStart..<text.index(lineStart, offsetBy: 2))
        } else {
            text.insert(contentsOf: "- ", at: lineStart)
        }
        selection = nil
        store.draftBody = text
    }

    /// Scheduled send and follow-up, each removable.
    @ViewBuilder private var status: some View {
        if store.draftSendAt != nil || store.draftFollowUpAt != nil || store.draftTrackOpens || store.draftTrackLinks {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let at = store.draftSendAt {
                        chip("Sends \(at.mobileScheduleLabel)", symbol: "clock.fill") { store.draftSendAt = nil }
                    }
                    if let at = store.draftFollowUpAt {
                        chip("Remind \(at.mobileScheduleLabel)", symbol: "bell.fill") { store.draftFollowUpAt = nil }
                    }
                    if store.draftTrackLinks {
                        chip("Tracking clicks", symbol: "link") { store.draftTrackLinks = false }
                    }
                    if store.draftTrackOpens {
                        chip("Tracking opens", symbol: "eye.fill") { store.draftTrackOpens = false }
                    }
                }
                .padding(.horizontal, Mobile.gutter)
                .padding(.vertical, 10)
            }
            rule
        }
    }

    private func chip(_ text: String, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
            Button("Remove", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(palette.accent.opacity(0.10), in: Capsule())
    }

    // MARK: Tools

    private var toolsBar: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Photo Library", systemImage: "photo.on.rectangle") { picksPhotos = true }
                Button("Choose File", systemImage: "folder") { importsFiles = true }
            } label: {
                tool("paperclip")
            }
            .accessibilityLabel("Attach")
            Menu {
                Button("Snippets & Templates", systemImage: "text.badge.plus") { tool = .snippets }
                Button("Free Times…", systemImage: "calendar") { tool = .availability }
                if runtime.backend.isConnected {
                    Button("Booking Link…", systemImage: "calendar.badge.clock") { tool = .booking }
                }
            } label: {
                tool("text.badge.plus")
            } primaryAction: {
                tool = .snippets
            }
            .accessibilityLabel("Insert")
            .accessibilityHint("Touch and hold for free times and booking links")
            if runtime.backend.canAccessWorkspace {
                Button { tool = .writer } label: { tool("sparkles") }
                    .accessibilityLabel("Write with AI")
            }
            Menu {
                Button("Send Later…", systemImage: "clock") { presenter.task = .sendLater }
                if store.draftAccount.isRemote {
                    Button("Remind Me If No Reply…", systemImage: "bell") { presenter.task = .composeFollowUp }
                    Toggle(isOn: $store.draftTrackOpens) { Label("Track Opens", systemImage: "eye") }
                    Toggle(isOn: $store.draftTrackLinks) { Label("Track Link Clicks", systemImage: "link") }
                }
            } label: {
                tool("clock")
            }
            .accessibilityLabel("Scheduling and tracking")
            if field == .body {
                Rectangle().fill(Mobile.hairline).frame(width: 1, height: 22).padding(.horizontal, 2)
                Button { wrap("**") } label: { tool("bold") }.accessibilityLabel("Bold")
                Button { wrap("*") } label: { tool("italic") }.accessibilityLabel("Italic")
                Button { bullet() } label: { tool("list.bullet") }.accessibilityLabel("List")
                Button { linkURL = "https://"; addsLink = true } label: { tool("link") }.accessibilityLabel("Insert Link")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .glassEffect(.regular, in: Capsule())
        // Only as wide as its tools; it grows when the formatting buttons appear.
        .animation(.snappy(duration: 0.25), value: field == .body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// Adds a paragraph at the end of the message body.
    private func insertBlock(_ text: String) {
        let body = store.draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        store.draftBody = body.isEmpty ? text : body + "\n\n" + text
        store.draftBodyRTF = nil
    }

    private func tool(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    // MARK: Fields

    private var fromRow: some View {
        HStack(spacing: 12) {
            Text("From").font(.system(size: 15)).foregroundStyle(.tertiary).frame(width: 44, alignment: .leading)
            Menu {
                ForEach(MailAccount.sendingAccounts) { account in
                    Button(account.titleWithEmail) { store.draftAccount = account }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.draftAccount.isConnected ? store.draftAccount.email : "Choose account").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(store.draftAccount.isConnected ? AnyShapeStyle(.primary) : AnyShapeStyle(palette.accent))
            }
            Spacer()
        }
        .padding(.horizontal, Mobile.gutter)
        .frame(minHeight: 50)
    }

    private func addressRow<Accessory: View>(_ label: String, text: Binding<String>, field: Field,
                                             @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 15)).foregroundStyle(.tertiary).frame(width: 44, alignment: .leading)
            TextField("", text: text, axis: .vertical)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($field, equals: field)
                .accessibilityLabel(label)
            accessory()
        }
        .padding(.horizontal, Mobile.gutter)
        .padding(.vertical, 14)
    }

    /// People you've written to before, matching the address being typed.
    @ViewBuilder private func suggestions(for target: Field, text: Binding<String>) -> some View {
        if field == target {
            let parts = text.wrappedValue.components(separatedBy: ",")
            let current = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
            let chosen = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            let matches = current.count < 1 ? [] : Array(store.recipientSuggestions(
                for: current, excluding: chosen,
                accountKey: store.draftAccount.isConnected ? store.draftAccount.rawValue : nil).prefix(4))
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches) { suggestion in
                        Button {
                            text.wrappedValue = (chosen + [suggestion.email]).joined(separator: ", ") + ", "
                        } label: {
                            HStack(spacing: 12) {
                                ParticipantPhoto(address: suggestion.email, name: suggestion.name, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.name.isEmpty ? suggestion.email : suggestion.name)
                                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if !suggestion.name.isEmpty {
                                        Text(suggestion.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Mobile.gutter)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.draftAttachments) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: "paperclip").foregroundStyle(.secondary)
                        Text(attachment.name).lineLimit(1).frame(maxWidth: 150)
                        Button("Remove \(attachment.name)", systemImage: "xmark.circle.fill") {
                            store.draftAttachments.removeAll { $0.id == attachment.id }
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Mobile.raised, in: Capsule())
                }
            }
            .padding(.horizontal, Mobile.gutter)
            .padding(.vertical, 12)
        }
    }

    private func attach(_ work: () throws -> Void) {
        do {
            try work()
            attachmentError = nil
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    /// Writes picked photos to temporary files, then imports them like any document.
    private func importPhotos() {
        let picked = photos
        guard !picked.isEmpty else { return }
        photos = []
        Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var urls: [URL] = []
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, item) in picked.enumerated() {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first
                    let name = "Photo \(index + 1).\(type?.preferredFilenameExtension ?? "jpg")"
                    let url = folder.appendingPathComponent(name)
                    try data.write(to: url)
                    urls.append(url)
                }
                attach { try store.addDraftAttachments(from: urls) }
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }
}
