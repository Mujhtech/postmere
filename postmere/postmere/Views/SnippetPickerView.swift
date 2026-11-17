import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SnippetPickerView: View {
    let snippets: [MailSnippet]
    let draft: MailTemplateDraft
    let onSave: (MailSnippet) -> Void
    let onDelete: (UUID) -> Void
    let onInsert: (String) -> Void
    let onApply: ((MailTemplateApplication) -> Void)?
    let onImportAttachments: (([URL]) throws -> [MailAttachment])?

    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var search = ""
    @State private var values: [String: String] = [:]
    @State private var applyMode: MailTemplateApplyMode?
    @State private var editingSnippet: MailSnippet?

    init(snippets: [MailSnippet], draft: MailTemplateDraft = .init(),
         onSave: @escaping (MailSnippet) -> Void, onDelete: @escaping (UUID) -> Void,
         onInsert: @escaping (String) -> Void,
         onApply: ((MailTemplateApplication) -> Void)? = nil,
         onImportAttachments: (([URL]) throws -> [MailAttachment])? = nil) {
        self.snippets = snippets
        self.draft = draft
        self.onSave = onSave
        self.onDelete = onDelete
        self.onInsert = onInsert
        self.onApply = onApply
        self.onImportAttachments = onImportAttachments
    }

    private var selectedSnippet: MailSnippet? { snippets.first { $0.id == selection } }
    private var filteredSnippets: [MailSnippet] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippets.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || $0.body.localizedCaseInsensitiveContains(query) || ($0.subject?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Snippets & Templates").font(PostmereTheme.sheetTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                if let snippet = selectedSnippet {
                    details(snippet)
                } else {
                    ContentUnavailableView {
                        PostmereLabel(snippets.isEmpty ? "Save a reusable message" : "Choose a snippet or template",
                                      symbol: "text.badge.plus", size: 40)
                    } description: {
                        Text("Snippets insert text at your cursor. Templates can also fill message fields and attach files.")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 760, height: 580)
        .onAppear { if selection == nil { selection = snippets.first?.id } }
        .onChange(of: selection) { values = [:]; applyMode = nil }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorView(snippet: snippet, onImportAttachments: onImportAttachments) { updated in
                onSave(updated)
                selection = updated.id
                values = [:]
                applyMode = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Search saved text", text: $search).textFieldStyle(.roundedBorder).padding(10)
            List(filteredSnippets, selection: $selection) { snippet in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(snippet.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if snippet.isTemplate {
                            Spacer(minLength: 0)
                            PostmereIcon("doc.text", size: 12).foregroundStyle(PostmereTheme.icon)
                                .accessibilityLabel("Template")
                        }
                    }
                    Text(snippet.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.vertical, 3).tag(snippet.id)
            }.listStyle(.sidebar).scrollIndicators(.never)
            Divider()
            Menu {
                Button("New Snippet") { editingSnippet = MailSnippet(title: "", body: "") }
                Button("New Template") { editingSnippet = MailSnippet(title: "", body: "", kind: .template) }
            } label: {
                PostmereLabel("New", symbol: "plus", size: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.menuStyle(.borderlessButton).padding(12)
        }.frame(width: 200)
    }

    private func details(_ snippet: MailSnippet) -> some View {
        let fields = MailTemplate.placeholderNames(in: snippet)
        let mode: MailTemplateApplyMode? = snippet.isTemplate ? (draft.hasContent ? applyMode : .replace) : .insert
        let prepared: Result<MailTemplateApplication, Error>? = mode.map { mode in
            Result { try MailTemplate.prepare(snippet, values: values, draft: draft, mode: mode) }
        }
        let application = try? prepared?.get()
        let previewBody = application.map { MailTemplate.resultingBody($0, draft: draft) }
            ?? SnippetPlaceholders.expand(MailTemplate.richBody(text: snippet.body, rtf: snippet.bodyRTF), values: values)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(snippet.title).font(.headline).lineLimit(2)
                Spacer()
                Text(snippet.isTemplate ? "Template" : "Quick insert").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !fields.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Fill in fields").font(.system(size: 12, weight: .semibold))
                            ForEach(fields, id: \.self) { field in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(field).font(.system(size: 12)).frame(width: 90, alignment: .leading)
                                    TextField(field, text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }))
                                        .textFieldStyle(.roundedBorder).accessibilityLabel(field)
                                }
                            }
                        }
                        Divider()
                    }
                    if snippet.isTemplate, draft.hasContent {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Apply to your draft").font(.system(size: 12, weight: .semibold))
                            Picker("Apply to draft", selection: $applyMode) {
                                Text("Append").tag(Optional(MailTemplateApplyMode.append))
                                Text("Replace").tag(Optional(MailTemplateApplyMode.replace))
                            }.pickerStyle(.segmented).labelsHidden()
                            Text(mode == .append
                                 ? "Adds recipients and files, keeps a filled subject, and adds text after your message."
                                 : mode == .replace
                                 ? "Replaces message text and files. Only included template fields replace draft fields."
                                 : "Choose Append or Replace to preview the changes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let application, snippet.isTemplate {
                        TemplateFieldsPreview(before: application.beforeHeaders, after: application.afterHeaders)
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snippet.isTemplate ? "Message preview" : "Insert at cursor")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        if previewBody.length == 0 {
                            Text("Empty message body").font(.system(size: 13)).foregroundStyle(.secondary)
                        } else {
                            Text(AttributedString(previewBody)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if case .failure(let error) = prepared {
                        Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.never)
            HStack {
                Button("Delete", role: .destructive) {
                    onDelete(snippet.id)
                    selection = snippets.first { $0.id != snippet.id }?.id
                }
                Button("Edit") { editingSnippet = snippet }
                Spacer()
                Button(snippet.isTemplate ? "Apply Template" : "Insert") {
                    guard let application else { return }
                    if let onApply { onApply(application) }
                    else { onInsert(application.body) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(application == nil || (snippet.isTemplate && onApply == nil))
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TemplateFieldsPreview: View {
    let before: MailTemplateHeaders
    let after: MailTemplateHeaders

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Message fields after applying").font(.system(size: 12, weight: .semibold))
            field("To", before: before.to, after: after.to)
            field("Cc", before: before.cc, after: after.cc)
            field("Bcc", before: before.bcc, after: after.bcc)
            field("Subject", before: before.subject, after: after.subject)
            HStack(alignment: .top, spacing: 12) {
                Text("Files").frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    if after.attachments.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(after.attachments) { attachment in
                        HStack(spacing: 7) {
                            AttachmentIconView(attachment: attachment, size: 24)
                            Text(attachment.name).lineLimit(1)
                        }
                    }
                    if before.attachments != after.attachments {
                        Text("\(before.attachments.count) → \(after.attachments.count) files").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.font(.system(size: 12))
        }
    }

    private func field(_ label: String, before: String, after: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(after.isEmpty ? "Empty" : after).foregroundStyle(after.isEmpty ? .secondary : .primary)
                if before != after, !before.isEmpty {
                    Text("Was: \(before)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if before == after { Text("Unchanged").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.font(.system(size: 12))
    }
}

private struct SnippetEditorView: View {
    let onImportAttachments: (([URL]) throws -> [MailAttachment])?
    let onSave: (MailSnippet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MailSnippet
    @State private var formatting = ComposeTextFormatting()
    @State private var showsImporter = false
    @State private var importError: String?

    init(snippet: MailSnippet, onImportAttachments: (([URL]) throws -> [MailAttachment])?, onSave: @escaping (MailSnippet) -> Void) {
        _draft = State(initialValue: snippet)
        self.onImportAttachments = onImportAttachments
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.to != nil || draft.cc != nil || draft.bcc != nil || draft.subject != nil || !draft.attachments.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.title.isEmpty ? (draft.isTemplate ? "New Template" : "New Snippet") : (draft.isTemplate ? "Edit Template" : "Edit Snippet"))
                    .font(PostmereTheme.sheetTitle)
                Spacer()
                if !draft.isTemplate {
                    Button("Add message fields") { draft.kind = .template }.font(.caption)
                }
            }
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            if draft.isTemplate {
                VStack(alignment: .leading, spacing: 8) {
                    includedField("To", keyPath: \.to, placeholder: "Recipients or {{email}}")
                    includedField("Cc", keyPath: \.cc, placeholder: "Cc recipients")
                    includedField("Bcc", keyPath: \.bcc, placeholder: "Bcc recipients")
                    includedField("Subject", keyPath: \.subject, placeholder: "Subject or {{project}}")
                    Text("Checked fields are included. Unchecked fields leave the draft unchanged.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    formatButton("Bold", symbol: "bold", active: formatting.isBold, action: formatting.toggleBold)
                    formatButton("Italic", symbol: "italic", active: formatting.isItalic, action: formatting.toggleItalic)
                    formatButton("Underline", symbol: "underline", active: formatting.isUnderlined, action: formatting.toggleUnderline)
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    Menu {
                        ForEach([11, 12, 14, 16, 18, 24], id: \.self) { size in
                            Button("\(size) pt") { formatting.setFontSize(CGFloat(size)) }
                        }
                    } label: { Text("\(Int(formatting.fontSize)) pt").font(.system(size: 12)).frame(width: 52) }
                    .menuStyle(.borderlessButton)
                    Button(action: formatting.showColorPanel) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: formatting.textColor)).frame(width: 14, height: 14)
                    }.buttonStyle(.borderless).help("Text color").accessibilityLabel("Text color")
                    Spacer()
                    Button(action: formatting.undo) { PostmereIcon("arrow.uturn.backward", size: 14) }
                        .buttonStyle(.borderless).disabled(!formatting.canUndo).help("Undo").accessibilityLabel("Undo")
                }.padding(.horizontal, 10).padding(.vertical, 8)
                Divider()
                ComposeBodyEditor(text: $draft.body, rtfData: $draft.bodyRTF, formatting: formatting)
                    .frame(minHeight: 160, maxHeight: .infinity)
            }
            .background(PostmereTheme.subtleFill, in: .rect(cornerRadius: PostmereTheme.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
            .accessibilityLabel(draft.isTemplate ? "Template message" : "Snippet text")
            if draft.isTemplate {
                attachmentEditor
            }
            Text("Use {{name}} in text, recipients, or the subject. You’ll fill it in before applying.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(24).frame(width: 660, height: draft.isTemplate ? 650 : 430)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data, .content], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                guard let onImportAttachments else { return }
                draft.attachments.append(contentsOf: try onImportAttachments(urls))
            } catch { importError = error.localizedDescription }
        }
        .alert("Couldn’t attach file", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    private func includedField(_ title: String, keyPath: WritableKeyPath<MailSnippet, String?>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: Binding(get: { draft[keyPath: keyPath] != nil }, set: { draft[keyPath: keyPath] = $0 ? (draft[keyPath: keyPath] ?? "") : nil }))
                .toggleStyle(.checkbox).frame(width: 84, alignment: .leading)
            TextField(placeholder, text: Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0 }))
                .textFieldStyle(.roundedBorder).disabled(draft[keyPath: keyPath] == nil)
                .accessibilityLabel("Template \(title)")
        }
    }

    private var attachmentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { showsImporter = true } label: { PostmereLabel("Attach File", symbol: "paperclip", size: 13) }
                    .disabled(onImportAttachments == nil)
            }
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(draft.attachments) { attachment in
                            HStack(spacing: 7) {
                                AttachmentIconView(attachment: attachment, size: 32)
                                Text(attachment.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 180)
                                Button { draft.attachments.removeAll { $0.id == attachment.id } } label: { PostmereIcon("xmark", size: 10) }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove \(attachment.name)")
                            }.padding(6).background(PostmereTheme.subtleFill, in: .rect(cornerRadius: 6))
                        }
                    }
                }.scrollIndicators(.never)
            }
        }
    }

    private func formatButton(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PostmereIcon(symbol, size: 14).frame(width: 26, height: 24)
                .foregroundStyle(active ? PostmereTheme.accentInk : PostmereTheme.icon)
                .background(active ? PostmereTheme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 4))
        }.buttonStyle(.borderless).help(title).accessibilityLabel(title).accessibilityValue(active ? "On" : "Off")
    }
}
