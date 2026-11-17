import SwiftUI

struct SharedTemplatesView: View {
    let runtime: MailRuntime
    @State private var summaries: [SharedSnippetSummary] = []
    @State private var detail: SharedSnippetDetail?
    @State private var error: String?
    @State private var notice: String?
    @State private var showsPublish = false
    @State private var selectedLocal: UUID?
    @State private var replacing: SharedSnippetDetail?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Templates shared with this workspace").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Publish Local Template…") { replacing = nil; showsPublish = true }.disabled(runtime.store.snippets.isEmpty)
            }.padding(18)
            HSplitView {
                List(summaries) { item in
                    Button { Task { await select(item.id) } } label: {
                        VStack(alignment: .leading, spacing: 5) { Text(item.title).font(.system(size: 13, weight: .medium)); Text(item.ownerEmail).font(.caption).foregroundStyle(.secondary) }
                            .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.scrollIndicators(.never).frame(minWidth: 210, idealWidth: 240, maxWidth: 290)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let detail {
                            Text(detail.template.title).font(.system(size: 21, weight: .semibold, design: .serif))
                            Text("Version \(detail.version) · \(detail.ownerEmail)").font(.caption).foregroundStyle(.secondary)
                            if let to = detail.template.to { LabeledContent("To", value: to) }
                            if let cc = detail.template.cc { LabeledContent("Cc", value: cc) }
                            if let bcc = detail.template.bcc { LabeledContent("Bcc", value: bcc) }
                            if let subject = detail.template.subject { LabeledContent("Subject", value: subject) }
                            Text(detail.template.body).font(.system(size: 13)).textSelection(.enabled)
                            ForEach(Array(detail.template.attachments.enumerated()), id: \.offset) { _, file in
                                PostmereLabel(file.filename, symbol: "paperclip", size: 13).font(.caption)
                            }
                            Button("Save a Copy to My Templates") {
                                do { let local = try WorkspaceTemplates.importTemplate(detail.template, store: runtime.store); runtime.store.saveSnippet(local); notice = "Saved locally. Choose it from Snippets in the composer." }
                                catch { self.error = error.localizedDescription }
                            }.buttonStyle(.borderedProminent)
                            if detail.ownerId == runtime.backend.credential?.userID {
                                Button("Publish Updated Version…") { replacing = detail; showsPublish = true }
                                Button("Remove Shared Template", role: .destructive) { Task { await remove(detail.id) } }
                            }
                        } else { Text("Select a team template to preview its text, recipients, and files.").foregroundStyle(.secondary) }
                        if let notice { Text(notice).font(.caption).foregroundStyle(PostmereTheme.accentInk) }
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never).frame(minWidth: 400)
            }
        }.task { await reload() }
            .sheet(isPresented: $showsPublish) { publishSheet }
    }

    private var publishSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(replacing == nil ? "Publish a team template" : "Publish a new version").font(PostmereTheme.sheetTitle)
            Picker("Local template", selection: $selectedLocal) {
                Text("Choose template").tag(Optional<UUID>.none)
                ForEach(runtime.store.snippets) { Text($0.title).tag(Optional($0.id)) }
            }
            if let snippet = runtime.store.snippets.first(where: { $0.id == selectedLocal }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let to = snippet.to { Text("To: \(to)") }
                        if let cc = snippet.cc { Text("Cc: \(cc)") }
                        if let bcc = snippet.bcc { Text("Bcc: \(bcc)") }
                        if let subject = snippet.subject { Text("Subject: \(subject)") }
                        Text(snippet.body)
                        ForEach(snippet.attachments) { Text("File: \($0.name)") }
                    }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never)
            }
            Text("Everyone in this workspace can read and copy this template, including its recipients and file contents.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Cancel") { showsPublish = false }.keyboardShortcut(.cancelAction); Spacer(); Button("Publish") { Task { await publish() } }.buttonStyle(.borderedProminent).disabled(busy || selectedLocal == nil) }
        }.padding(24).frame(width: 570, height: 480)
    }

    private func reload() async { do { let value: SharedSnippetList = try await runtime.backend.request("GET", "/v1/shared/snippets"); summaries = value.snippets } catch { self.error = error.localizedDescription } }
    private func select(_ id: UUID) async { do { detail = try await runtime.backend.request("GET", "/v1/shared/snippets/\(id.uuidString)"); error = nil; notice = nil } catch { self.error = error.localizedDescription } }
    private func remove(_ id: UUID) async { do { let _: BackendEmpty = try await runtime.backend.request("DELETE", "/v1/shared/snippets/\(id.uuidString)"); detail = nil; await reload() } catch { self.error = error.localizedDescription } }
    private func publish() async {
        guard let snippet = runtime.store.snippets.first(where: { $0.id == selectedLocal }) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let template = try WorkspaceTemplates.export(snippet)
            if let replacing {
                detail = try await runtime.backend.request("PUT", "/v1/shared/snippets/\(replacing.id.uuidString)", body: SharedTemplateUpdate(template: template, expectedVersion: replacing.version))
            } else { detail = try await runtime.backend.request("POST", "/v1/shared/snippets", body: SharedTemplateInput(template: template)) }
            showsPublish = false; await reload()
        } catch { self.error = error.localizedDescription }
    }
}
