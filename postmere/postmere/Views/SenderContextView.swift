import SwiftUI

struct SenderContextView: View {
    @Bindable var store: MailStore
    let email: String
    let accountKey: String
    let displayName: String
    let onOpenMessage: (MailMessage) -> Void
    let onOpenAttachment: (MailAttachment, MailMessage) -> Void
    private let notes: MailContactNotesStore

    init(store: MailStore, email: String, accountKey: String, displayName: String = "",
         notes: MailContactNotesStore? = nil,
         onOpenMessage: @escaping (MailMessage) -> Void,
         onOpenAttachment: @escaping (MailAttachment, MailMessage) -> Void) {
        self.store = store
        self.email = MailContactIdentity.email(email)
        self.accountKey = accountKey
        self.displayName = displayName
        self.notes = notes ?? .shared
        self.onOpenMessage = onOpenMessage
        self.onOpenAttachment = onOpenAttachment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PostmereSheetHeader(displayName.isEmpty ? email : displayName,
                                subtitle: displayName.isEmpty ? nil : email)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("VIP for this account", isOn: Binding(get: {
                    store.hasSenderVIP(email: email, accountKey: accountKey)
                }, set: { _ = store.setSenderVIP($0, email: email, accountKey: accountKey) }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                if let error = store.operationError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            Divider()
            SenderHistoryView(store: store, email: email, accountKey: accountKey,
                              onOpenMessage: onOpenMessage, onOpenAttachment: onOpenAttachment)
            Divider()
            ContactNoteEditor(email: email, accountKey: accountKey, notes: notes)
                .id("\(accountKey)|\(email)")
                .padding(20)
        }
        .frame(minWidth: 320, idealWidth: 370, maxWidth: 440, minHeight: 560)
    }
}

private struct SenderHistoryView: View {
    @Bindable var store: MailStore
    let email: String
    let accountKey: String
    let onOpenMessage: (MailMessage) -> Void
    let onOpenAttachment: (MailAttachment, MailMessage) -> Void
    @State private var section = 0

    var body: some View {
        let context = store.senderContext(email: email, accountKey: accountKey)
        VStack(spacing: 12) {
            HStack {
                Text("\(context.conversations.count) conversations · \(context.messageCount) messages")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 14)
            Picker("Contact history", selection: $section) {
                Text("Conversations").tag(0)
                Text("Files (\(context.attachments.count))").tag(1)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20)
            if section == 0 {
                if context.conversations.isEmpty {
                    Text("No conversations with this contact in this account.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(24)
                    Spacer()
                } else {
                    List(context.conversations) { conversation in
                        Button { onOpenMessage(conversation.latestMessage) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(conversation.latestMessage.displaySubject)
                                        .font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Spacer(minLength: 4)
                                    Text(conversation.latestMessage.sentAt, format: .dateTime.month(.abbreviated).day())
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(conversation.latestMessage.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                if conversation.messageCount > 1 {
                                    Text("\(conversation.messageCount) messages").font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain)
                    }.listStyle(.inset).scrollIndicators(.never)
                }
            } else {
                if context.attachments.isEmpty {
                    Text("No files shared in these conversations.").font(.system(size: 12)).foregroundStyle(.secondary).padding(24)
                    Spacer()
                } else {
                    List(context.attachments) { item in
                        Button { onOpenAttachment(item.attachment, item.message) } label: {
                            HStack(spacing: 10) {
                                AttachmentIconView(attachment: item.attachment, size: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(item.message.displaySubject).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    Text(item.attachment.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 4).contentShape(.rect)
                        }.buttonStyle(.plain)
                            .disabled(item.attachment.localURL == nil && item.attachment.providerAttachmentID == nil)
                    }.listStyle(.inset).scrollIndicators(.never)
                }
            }
        }.frame(maxHeight: .infinity)
    }
}

private struct ContactNoteEditor: View {
    let email: String
    let accountKey: String
    let notes: MailContactNotesStore
    @State private var text: String
    @State private var lastSaved: String
    @State private var saveError: String?

    init(email: String, accountKey: String, notes: MailContactNotesStore) {
        self.email = email
        self.accountKey = accountKey
        self.notes = notes
        let value = notes.note(for: email, accountKey: accountKey)
        _text = State(initialValue: value)
        _lastSaved = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Private contact note").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Only on this Mac").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            TextEditor(text: Binding(get: { text }, set: { value in
                text = value
                do {
                    try notes.save(value, for: email, accountKey: accountKey)
                    lastSaved = value
                    saveError = nil
                } catch { saveError = error.localizedDescription }
            }))
            .font(.system(size: 12)).scrollContentBackground(.hidden).scrollIndicators(.never)
            .frame(height: 105).padding(7)
            .background(PostmereTheme.subtleFill, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PostmereTheme.rule) }
            .accessibilityLabel("Private note about \(email)")
            if let error = saveError ?? notes.storageError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: notes.note(for: email, accountKey: accountKey)) { _, newValue in
            if text == lastSaved { text = newValue; lastSaved = newValue }
        }
    }
}
