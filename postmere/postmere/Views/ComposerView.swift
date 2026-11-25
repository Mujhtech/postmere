import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.mailboxColors) private var mailboxColors
    @Environment(\.mailboxInset) private var inset
    @Environment(\.postmereAccent) private var palette
    @Bindable var store: MailStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(MailRuntime.self) private var runtime
    @AppStorage("markdownSubstitutions") private var markdownEnabled = true
    @FocusState private var focusedField: Field?
    @State private var formatting = ComposeTextFormatting()
    @State private var showsCc = true
    @State private var showsBcc = false
    @State private var showsFormatting = true
    @State private var isChoosingAttachments = false
    @State private var isShowingAlert = false
    @State private var attachmentError: String?
    @State private var schedulePurpose: MailSchedulePurpose?
    @State private var confirmsMissingAttachment = false
    /// The quoted message under a reply or forward is folded away until asked for.
    @State private var showsQuote = false
    @State private var quoteFold = QuoteFold()
    @State private var proofreads = false
    @State private var showsSnippets = false
    @State private var showsAvailability = false
    @State private var showsAIWriting = false
    @State private var showsBookingLinks = false
    @State private var showsTeamTemplates = false

    private enum Field: Hashable { case recipient, cc, bcc, subject }

    private var canvas: Color {
        theme == .native ? PostmereTheme.paper : mailboxColors.canvas
    }

    private var barStyle: AnyShapeStyle {
        theme == .native ? AnyShapeStyle(.bar) : AnyShapeStyle(inset)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.persistenceError {
                HStack(spacing: 10) {
                    Label { Text(error) } icon: {
                        PostmereIcon("exclamationmark.circle", size: 14).foregroundStyle(.red)
                    }.font(.caption)
                    Spacer()
                    Button("Retry", action: store.retryPersistence).controlSize(.small)
                }.padding(12).background(barStyle)
            }
            addressFields
            if !store.draftAccount.isConnected { accountConnectionNotice }
            if store.draftSendAt != nil || store.draftFollowUpAt != nil { schedulingSummary }
            if showsFormatting { formattingBar }
            ComposeBodyEditor(text: bodyText, rtfData: bodyRTF, formatting: formatting,
                              markdownEnabled: markdownEnabled,
                              onCaptureAttachments: { try store.addDraftAttachments(from: $0) },
                              onCaptureError: showAttachmentError)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { aiWriting }
                .onChange(of: store.pendingWriterPrompt, initial: true) { openWriterIfAsked() }
            if let quote = MailQuotedReply.split(store.draftBody)?.quote { quotedToggle(quote) }
            if !store.draftAttachments.isEmpty { attachmentList }
        }
        .background(canvas)
        .containerBackground(canvas, for: .window)
        .frame(minWidth: 640, idealWidth: 840, minHeight: 520, idealHeight: 780)
        .navigationTitle(store.draftSubject.isEmpty ? "New Message" : store.draftSubject)
        .focusedSceneValue(\.mailStore, store)
        .focusedSceneValue(\.isComposerWindow, true)
        .focusedSceneValue(\.composeFormatting, formatting)
        .background {
            ComposeWindowLifecycle(store: store, requestClose: requestDismissal)
                .frame(width: 0, height: 0)
            Button("Attach Files…") { isChoosingAttachments = true }
                .keyboardShortcut("a", modifiers: [.command, .shift]).hidden()
            Button("Queue Message", action: attemptSend)
                .keyboardShortcut(.return, modifiers: .command).disabled(!store.canSendDraft).hidden()
            Button("Write with AI", action: toggleAIWriting)
                .keyboardShortcut("j", modifiers: .command).hidden()
        }
        .toolbar { composeToolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showsSnippets) {
            SnippetPickerView(snippets: store.snippets, draft: store.draftForTemplates, onSave: store.saveSnippet,
                              onDelete: store.deleteSnippet, onInsert: formatting.insertSnippet,
                              onApply: { application in
                                  _ = formatting.applyTemplate(application, updateFields: store.applyTemplateHeaders)
                                  if !store.draftCc.isEmpty { showsCc = true }
                                  if !store.draftBcc.isEmpty { showsBcc = true }
                              }, onImportAttachments: store.importTemplateAttachments)
        }
        .sheet(isPresented: $proofreads) { MailProofreadSheet(runtime: runtime) { attemptSend() } }
        .confirmationDialog("Send without an attachment?", isPresented: $confirmsMissingAttachment) {
            Button("Attach Files…") { isChoosingAttachments = true }
            Button("Send Anyway") { store.sendDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your message mentions an attachment, but nothing is attached.")
        }
        .sheet(item: $schedulePurpose) { purpose in
            MailScheduleSheet(purpose: purpose) { date, conditional in
                if purpose == .sendLater { store.draftSendAt = date }
                else { store.draftFollowUpAt = date; store.draftFollowUpOnlyIfNoReply = conditional }
            }
        }
        .sheet(isPresented: $showsAvailability) { AvailabilityPickerView(onInsert: formatting.insertText) }
        .sheet(isPresented: $showsBookingLinks) {
            VStack(spacing: 0) {
                PostmereSheetHeader("Booking links")
                BookingLinksView(session: runtime.backend) { text in formatting.insertText(text); showsBookingLinks = false }
            }.frame(width: 650, height: 540)
                .mailPanelSurface()
        }
        .sheet(isPresented: $showsTeamTemplates) {
            VStack(spacing: 0) {
                PostmereSheetHeader("Team templates")
                SharedTemplatesView(runtime: runtime)
            }.frame(width: 760, height: 570)
                .mailPanelSurface()
        }
        .onAppear {
            if !store.isComposing { store.beginCompose() }
            prepareSession()
        }
        .onChange(of: store.isComposing) {
            if store.isComposing {
                prepareSession()
            } else {
                Task { @MainActor in
                    await Task.yield()
                    guard !store.isComposing else { return }
                    dismissWindow(id: "compose")
                }
            }
        }
        .onExitCommand(perform: requestDismissal)
        .fileImporter(isPresented: $isChoosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { try store.addDraftAttachments(from: result.get()) }
            catch { showAttachmentError(error) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            do {
                try store.addDraftAttachments(from: urls)
                return true
            } catch {
                showAttachmentError(error)
                return false
            }
        }
        .alert("Couldn’t add attachment", isPresented: Binding(get: { isShowingAlert && attachmentError != nil },
                                                              set: { if !$0 { isShowingAlert = false; attachmentError = nil } })) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
        // Drawn by Postmere rather than as a system alert, so Save Draft takes the chosen accent.
        .sheet(isPresented: Binding(get: { isShowingAlert && attachmentError == nil }, set: { if !$0 { isShowingAlert = false } })) {
            PostmereDecisionSheet(
                title: "Save changes to this message?",
                message: "Save a draft to keep your changes, or discard them.",
                primary: .init(title: "Save Draft") { store.saveDraft() },
                destructive: .init(title: "Discard Changes", role: .destructive) { store.discardDraftChanges() },
                cancel: .init(title: "Keep Editing", role: .cancel) {})
        }
    }

    @ToolbarContentBuilder
    private var composeToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button(action: formatting.undo) {
                PostmereLabel("Undo", symbol: "arrow.uturn.backward", size: 17)
                    .foregroundStyle(PostmereTheme.icon)
            }
            .disabled(!formatting.canUndo)
            .help("Undo · ⌘Z")
            Button { showsFormatting.toggle() } label: {
                PostmereLabel("Formatting", symbol: "textformat", size: 17)
                    .foregroundStyle(PostmereTheme.icon)
            }
            .help(showsFormatting ? "Hide formatting" : "Show formatting")
            .accessibilityValue(showsFormatting ? "Shown" : "Hidden")
            Button(action: formatting.showCharacterPalette) {
                PostmereLabel("Emoji & Symbols", symbol: "face.smiling", size: 17)
                    .foregroundStyle(PostmereTheme.icon)
            }
            .help("Emoji & Symbols")
            if runtime.backend.canAccessWorkspace {
                Button(action: toggleAIWriting) {
                    PostmereLabel("Write with AI", symbol: "sparkles", size: 17)
                        .foregroundStyle(palette.accentInk)
                }
                .help("Write or edit with AI · ⌘J")
                .accessibilityValue(showsAIWriting ? "Open" : "Closed")
            }
            Menu {
                Button("Insert Snippet or Template…") { showsSnippets = true }
                Button("Insert Availability…") { showsAvailability = true }
                if runtime.backend.isConnected {
                    Button("Insert Booking Link…") { showsBookingLinks = true }
                    Button("Team Templates…") { showsTeamTemplates = true }
                }
            } label: {
                PostmereLabel("Snippets", symbol: "text.badge.plus", size: 17)
                    .foregroundStyle(PostmereTheme.icon)
            } primaryAction: { showsSnippets = true }
            .help("Insert a saved snippet or availability")
        }
        ToolbarSpacer(.fixed, placement: .principal)
        ToolbarItem(placement: .principal) {
            Menu {
                Toggle("Cc Address Field", isOn: $showsCc)
                    .disabled(!store.draftCc.isEmpty)
                Toggle("Bcc Address Field", isOn: $showsBcc)
                    .disabled(!store.draftBcc.isEmpty)
            } label: {
                PostmereLabel("Header Fields", symbol: "rectangle.topthird.inset.filled", size: 17)
                    .foregroundStyle(PostmereTheme.icon)
            }
            .help("Show Cc and Bcc address fields")
        }
        ToolbarSpacer(.fixed, placement: .principal)
        ToolbarItem(placement: .principal) {
            ComposeAttachmentMenuButton(onChooseFiles: { isChoosingAttachments = true },
                                        onCapture: { try store.addDraftAttachments(from: $0) },
                                        onError: showAttachmentError)
                .frame(width: 28, height: 24)
            .help("Attach files · ⇧⌘A")
        }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Send Now") { store.draftSendAt = nil; attemptSend() }.disabled(!store.canSendDraft)
                if runtime.backend.canAccessWorkspace {
                    Button("Proofread and Send…") { proofreads = true }.disabled(!store.canSendDraft)
                }
                Button("Send Later…") { schedulePurpose = .sendLater }
                if store.draftSendAt != nil { Button("Clear Send Schedule") { store.draftSendAt = nil } }
                Divider()
                Button("Remind Me to Follow Up…") { schedulePurpose = .composeFollowUp }
                if store.draftFollowUpAt != nil { Button("Clear Follow-up Reminder") { store.draftFollowUpAt = nil } }
                if store.draftAccount.isRemote {
                    Divider()
                    Toggle("Track opens for this message", isOn: $store.draftTrackOpens)
                    Toggle("Track link clicks for this message", isOn: $store.draftTrackLinks)
                    Text("Activity shows image and link requests. Privacy proxies can affect counts.")
                }
            } label: {
                PostmereLabel(store.draftSendAt != nil ? "Schedule" : "Send", symbol: "arrow.up", size: 17)
                    .foregroundStyle(store.canSendDraft ? palette.accentInk : .secondary)
            } primaryAction: {
                attemptSend()
            }
            .disabled(!store.draftAccount.isConnected)
            .help(store.draftValidationMessage ?? "Queue email for delivery · ⌘Return")
        }
    }

    // MARK: Quoted message

    /// While the quote is folded, the editor holds only what the person writes;
    /// the quote, with its formatting, is joined back on every change.
    private var bodyText: Binding<String> {
        Binding(
            get: {
                guard !showsQuote, let split = MailQuotedReply.split(store.draftBody) else { return store.draftBody }
                return split.head
            },
            set: { newValue in
                if !showsQuote, let quote = MailQuotedReply.split(store.draftBody)?.quote {
                    store.draftBody = MailQuotedReply.join(head: newValue, quote: quote)
                } else {
                    store.draftBody = newValue
                }
            })
    }

    private var bodyRTF: Binding<Data?> {
        Binding(
            get: {
                guard !showsQuote, let split = MailQuotedReply.split(store.draftBody) else { return store.draftBodyRTF }
                return quoteFold.head(of: store.draftBodyRTF, body: store.draftBody, quoteLength: split.quote.utf16.count)
            },
            set: { newValue in
                guard !showsQuote, let quote = MailQuotedReply.split(store.draftBody)?.quote else {
                    store.draftBodyRTF = newValue
                    return
                }
                store.draftBodyRTF = quoteFold.join(head: newValue, previous: store.draftBodyRTF, body: store.draftBody,
                                                    quoteLength: quote.utf16.count)
            })
    }

    private func quotedToggle(_ quote: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showsQuote.toggle() }
        } label: {
            HStack(spacing: 10) {
                PostmereIcon(showsQuote ? "chevron.up" : "ellipsis", size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 18)
                    .background(.quaternary, in: Capsule())
                Text(showsQuote ? "Hide quoted text" : "Show quoted text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accentInk)
                Text(MailQuotedReply.title(of: quote))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The quoted message is always sent with your reply")
    }

    /// Asks first when the message mentions an attachment and has none.
    private func attemptSend() {
        guard store.canSendDraft else { return }
        if store.draftAttachments.isEmpty && MailAttachmentReminder.mentionsAttachment(store.draftBody) {
            confirmsMissingAttachment = true
        } else {
            store.sendDraft()
        }
    }

    /// Opens the writer when something asked for a draft, such as Draft intro.
    private func openWriterIfAsked() {
        guard store.pendingWriterPrompt != nil, runtime.backend.canAccessWorkspace, !showsAIWriting else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { showsAIWriting = true }
    }

    private func toggleAIWriting() {
        guard runtime.backend.canAccessWorkspace else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { showsAIWriting.toggle() }
    }

    /// The inline writer floats over the bottom of the body; an empty body shows an invitation.
    @ViewBuilder private var aiWriting: some View {
        if showsAIWriting {
            ComposeAIWriter(runtime: runtime, store: store, formatting: formatting) {
                withAnimation(.spring(duration: 0.35, bounce: 0.1)) { showsAIWriting = false }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .bottom)))
        } else if runtime.backend.canAccessWorkspace,
                  store.draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Spacer()
                ComposeAIHint(action: toggleAIWriting)
            }
            .padding(20)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
        }
    }

    private var sendingAccountLabel: String {
        if store.draftAccount.isConnected {
            return store.draftAccount.titleWithEmail
        }
        let previousEmail = store.draftProviderAccountEmail ?? store.draftAccount.email
        return previousEmail.isEmpty ? "Choose an account" : "\(previousEmail) · Not connected"
    }

    private var accountConnectionNotice: some View {
        HStack(spacing: 12) {
            PostmereIcon("envelope", size: 16).foregroundStyle(PostmereTheme.icon)
            Text(MailAccount.sendingAccounts.isEmpty
                 ? "Connect an email account to your workspace before sending this draft."
                 : "Choose a connected account in From before sending this draft.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            AccountSettingsButton(title: MailAccount.allCases.isEmpty ? "Add Account" : "Manage Accounts")
                .controlSize(.small)
        }.padding(.horizontal, 24).padding(.vertical, 10).background(barStyle)
    }

    private var addressFields: some View {
        VStack(spacing: 0) {
            recipientRow("To:", text: $store.draftTo, field: .recipient)
            Divider()
            if showsCc {
                recipientRow("Cc:", text: $store.draftCc, field: .cc)
                Divider()
            }
            if showsBcc {
                recipientRow("Bcc:", text: $store.draftBcc, field: .bcc)
                Divider()
            }
            HStack(spacing: 1) {
                fieldLabel("Subject:")
                TextField("", text: $store.draftSubject)
                    .focused($focusedField, equals: .subject)
                    .accessibilityLabel("Subject")
            }
            .padding(.trailing, 24)
            .frame(height: 40)
            Divider()
            HStack(spacing: 1) {
                fieldLabel("From:")
                Menu {
                    ForEach(MailAccount.allCases) { account in
                        Button { store.draftAccount = account } label: {
                            if account == store.draftAccount {
                                PostmereLabel(account.titleWithEmail, symbol: "checkmark", size: 14)
                            } else {
                                Text("\(account.titleWithEmail)\(account.isConnected ? "" : " · Reconnect required")")
                            }
                        }.disabled(!account.isConnected)
                    }
                    if !MailAccount.allCases.isEmpty { Divider() }
                    AccountSettingsButton(title: MailAccount.allCases.isEmpty ? "Add an Account…" : "Manage Accounts…")
                } label: {
                    Text(sendingAccountLabel).lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
                .accessibilityLabel("Sending account")
                .accessibilityValue(sendingAccountLabel)
                Spacer(minLength: 0)
            }
            .padding(.trailing, 24)
            .frame(height: 40)
            Divider()
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(.leading, 24)
        .padding(.top, 2)
    }

    private var schedulingSummary: some View {
        HStack(spacing: 14) {
            if let date = store.draftSendAt {
                PostmereLabel("Send \(date.formatted(date: .abbreviated, time: .shortened))", symbol: "clock", size: 14)
            }
            if let date = store.draftFollowUpAt {
                PostmereLabel("Follow up \(date.formatted(date: .abbreviated, time: .shortened))", symbol: "bell", size: 14)
            }
            Spacer(minLength: 0)
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 9)
    }

    private func recipientRow(_ label: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: 1) {
            fieldLabel(label)
            TextField("", text: text)
                .focused($focusedField, equals: field)
                .accessibilityLabel("\(label.dropLast()) recipients")
                .help(field == .bcc ? "Hidden from other recipients. Separate addresses with commas or semicolons."
                      : "Separate email addresses with commas or semicolons.")
        }
        .padding(.trailing, 24)
        .frame(height: 40)
        .overlay(alignment: .topLeading) {
            if focusedField == field {
                let others = [store.draftTo, store.draftCc, store.draftBcc].filter { $0 != text.wrappedValue }.flatMap { MailAddressList($0).addresses }
                let suggestions = store.recipientSuggestions(for: text.wrappedValue, excluding: others)
                if !suggestions.isEmpty {
                    RecipientSuggestionsView(suggestions: suggestions) {
                        text.wrappedValue = MailRecipientSuggestions.replacingCurrentToken(in: text.wrappedValue, with: $0)
                    }.frame(width: 360).offset(x: 50, y: 39).shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                }
            }
        }.zIndex(focusedField == field ? 10 : 0)
    }

    private var formattingBar: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Button { showsFormatting = false } label: {
                    PostmereIcon("chevron.left", size: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 24)
                }
                .help("Hide formatting")
                .accessibilityLabel("Hide formatting")
                Divider().frame(height: 14)
                Menu {
                    Picker("Text size", selection: Binding(
                        get: { Int(formatting.fontSize.rounded()) },
                        set: { formatting.setFontSize(CGFloat($0)) }
                    )) {
                        ForEach([11, 12, 13, 14, 16, 18, 20, 24, 32], id: \.self) { size in
                            Text("\(size) pt").tag(size)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("Aa").font(.system(size: 13)).frame(width: 25, height: 24)
                }
                .help("Text size")
                .accessibilityLabel("Text size")
                Button(action: formatting.showColorPanel) {
                    Circle()
                        .fill(Color(nsColor: formatting.textColor))
                        .padding(3)
                        .overlay {
                            Circle().strokeBorder(PostmereTheme.icon.opacity(0.45), lineWidth: 0.75)
                        }
                        .frame(width: 18, height: 18)
                        .frame(width: 23, height: 24)
                }
                .help("Text color")
                .accessibilityLabel("Text color")
                MailFormattingButton(title: "Bold", symbol: "bold", active: formatting.isBold, action: formatting.toggleBold)
                Button(action: formatting.showListPanel) {
                    PostmereIcon("list.bullet", size: 15).frame(width: 25, height: 24)
                }
                .help("Lists")
                .accessibilityLabel("Lists")
                Menu {
                    Button { formatting.setAlignment(.left) } label: {
                        PostmereLabel("Align Left", symbol: "text.alignleft", size: 16)
                    }
                    Button { formatting.setAlignment(.center) } label: {
                        PostmereLabel("Center", symbol: "text.aligncenter", size: 16)
                    }
                    Button { formatting.setAlignment(.right) } label: {
                        PostmereLabel("Align Right", symbol: "text.alignright", size: 16)
                    }
                } label: {
                    PostmereIcon(alignmentSymbol, size: 15).frame(width: 25, height: 24)
                }
                .help("Text alignment")
                .accessibilityLabel("Text alignment")
                Menu {
                    Toggle("Italic", isOn: Binding(get: { formatting.isItalic }, set: { _ in formatting.toggleItalic() }))
                    Toggle("Underline", isOn: Binding(get: { formatting.isUnderlined }, set: { _ in formatting.toggleUnderline() }))
                } label: {
                    PostmereIcon("ellipsis", size: 15).frame(width: 23, height: 24)
                }
                .help("More formatting")
                .accessibilityLabel("More formatting")
            }
            .font(PostmereTheme.utilitySymbol)
            .foregroundStyle(PostmereTheme.icon)
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(height: 26)
            .glassEffect(.regular, in: .capsule)
        }
        .controlSize(.small)
        .padding(.trailing, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var alignmentSymbol: String {
        switch formatting.alignment {
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        default: "text.alignleft"
        }
    }


    private var attachmentList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(store.draftAttachments) { attachment in
                    HStack(spacing: 9) {
                        AttachmentIconView(attachment: attachment, size: 36)
                        Text(attachment.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(attachment.localURL == nil && attachment.providerAttachmentID == nil ? "Sample" : attachment.detail)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button { store.removeDraftAttachment(attachment.id) } label: {
                            PostmereIcon("xmark.circle.fill", size: 15).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove attachment \(attachment.name)")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(inset, in: RoundedRectangle(cornerRadius: PostmereTheme.cardRadius))
                }
            }
        }
        .frame(height: min(CGFloat(store.draftAttachments.count) * 56, 106))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func prepareSession() {
        showsCc = true
        showsBcc = !store.draftBcc.isEmpty
        isChoosingAttachments = false
        isShowingAlert = false
        attachmentError = nil
        if store.draftTo.isEmpty {
            focusedField = .recipient
        } else {
            focusedField = nil
            formatting.focus()
        }
    }

    private func requestDismissal() {
        guard !isShowingAlert else { return }
        if store.hasUnsavedDraftChanges {
            attachmentError = nil
            isShowingAlert = true
        } else {
            store.discardDraftChanges()
        }
    }

    private func showAttachmentError(_ error: Error) {
        attachmentError = error.localizedDescription
        isShowingAlert = true
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: 50, alignment: .leading)
    }
}

/// Splits the rich copy of a reply between what the editor shows and the folded
/// quote. Remembers its last answer so the editor's own formatting round-trips
/// without being reapplied on every keystroke.
private final class QuoteFold {
    private var combined: Data?
    private var head: Data?

    func head(of rtf: Data?, body: String, quoteLength: Int) -> Data? {
        guard let rtf else { return nil }
        if rtf == combined { return head }
        let rich = MailTemplate.richBody(text: body, rtf: rtf)
        let headLength = max(0, rich.length - quoteLength)
        let result = MailTemplate.encodeRTF(rich.attributedSubstring(from: NSRange(location: 0, length: headLength)))
        combined = rtf
        head = result
        return result
    }

    /// The editor's new head joined to the quote's formatting from the previous rich copy.
    /// `body` is already the new plain text, head and quote.
    func join(head newHead: Data?, previous: Data?, body: String, quoteLength: Int) -> Data? {
        let headLength = (body as NSString).length - quoteLength
        let headText = (body as NSString).substring(to: max(0, headLength))
        let rich = NSMutableAttributedString(attributedString: MailTemplate.richBody(text: headText, rtf: newHead))
        let previousRich = previous.flatMap { data in
            try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        let quoteText = (body as NSString).substring(from: max(0, headLength))
        if let previousRich, previousRich.length >= quoteLength,
           previousRich.attributedSubstring(from: NSRange(location: previousRich.length - quoteLength, length: quoteLength)).string == quoteText {
            rich.append(previousRich.attributedSubstring(from: NSRange(location: previousRich.length - quoteLength, length: quoteLength)))
        } else {
            rich.append(MailTemplate.richBody(text: quoteText, rtf: nil))
        }
        let result = MailTemplate.encodeRTF(rich)
        combined = result
        head = newHead
        return result
    }
}
