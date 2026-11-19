import SwiftUI

struct MailSearchTokenControls: View {
    @Bindable var store: MailStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !store.searchTokens.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(store.searchTokens.filter { $0.kind == .term }) { token in
                            SearchTokenChip(store: store, token: token)
                        }
                    }
                }
            }
            ForEach(Array(store.searchIssues.prefix(2))) { issue in
                Text(issue.message).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SearchTokenChip: View {
    @Environment(\.postmereAccent) private var palette
    @Bindable var store: MailStore
    let token: MailSearchToken
    @State private var showsEditor = false
    @State private var replacement = ""

    var body: some View {
        HStack(spacing: 5) {
            Button {
                replacement = token.rawText
                showsEditor = true
            } label: {
                Text(token.rawText).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
            }
            .buttonStyle(.plain)
            .help("Edit \(token.rawText)")
            .popover(isPresented: $showsEditor) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Edit search condition").font(.system(size: 13, weight: .semibold))
                    TextField("Search condition", text: $replacement).textFieldStyle(.roundedBorder)
                        .onSubmit(apply)
                    HStack {
                        Spacer()
                        Button("Cancel") { showsEditor = false }.keyboardShortcut(.cancelAction)
                        Button("Apply", action: apply).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }.padding(18).frame(width: 300)
            }
            Button { store.removeSearchToken(token.id) } label: {
                PostmereIcon("xmark", size: 9).frame(width: 14, height: 16)
            }.buttonStyle(.plain).help("Remove \(token.rawText)")
                .accessibilityLabel("Remove search condition \(token.rawText)")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(token.isExcluded ? Color.secondary : palette.accentInk)
        .padding(.leading, 7).padding(.trailing, 3).padding(.vertical, 3)
        .background(PostmereTheme.subtleFill, in: .rect(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(PostmereTheme.rule.opacity(0.7)) }
    }

    private func apply() {
        store.updateSearchToken(token.id, with: replacement)
        showsEditor = false
    }
}

struct MailSearchHelp: View {
    @Environment(\.postmereAccent) private var palette
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let examples: [(String, String)] = [
        ("from:clara", "From a person or address"),
        ("to:alex", "Sent to a person or address"),
        ("subject:\"design review\"", "An exact phrase in the subject"),
        ("after:2026-11-01 before:2026-12-01", "A date range"),
        ("has:attachment filetype:pdf", "Messages with PDF files"),
        ("is:unread -is:starred", "Unread, excluding starred mail"),
        ("is:vip OR is:needsreply", "VIP senders or Needs Reply")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search your mail").font(PostmereTheme.sheetTitle)
            Text("Use spaces to match every condition, OR for alternatives, quotes for phrases, and − to exclude.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(examples, id: \.0) { query, explanation in
                Button {
                    onUse(query)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(query).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(palette.accentInk)
                        Text(explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Text("Search currently includes messages saved on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 370)
    }
}
