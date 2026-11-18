import AppKit
import SwiftUI

/// A compact Settings section that accepts provider-independent account keys.
struct SignatureEditorView: View {
    let accounts: [MailSignatureAccount]
    let preferences: MailSignatureStore
    @State private var selectedAccountID: String
    @State private var signature: MailSignature
    @State private var formatting = ComposeTextFormatting()
    @State private var saveError: String?

    init(accounts: [MailSignatureAccount], preferences: MailSignatureStore? = nil) {
        let preferences = preferences ?? MailSignatureStore.shared
        self.accounts = accounts
        self.preferences = preferences
        let accountID = accounts.first?.id ?? ""
        _selectedAccountID = State(initialValue: accountID)
        _signature = State(initialValue: preferences.signature(for: accountID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if accounts.isEmpty {
                Text("Add an account to set its signature.").foregroundStyle(.secondary)
            } else {
                Picker("Account", selection: Binding(get: { selectedAccountID }, set: selectAccount)) {
                    ForEach(accounts) { account in
                        Text(account.detail.isEmpty ? account.title : "\(account.title) · \(account.detail)").tag(account.id)
                    }
                }
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        MailFormattingButton(title: "Bold", symbol: "bold", active: formatting.isBold, action: formatting.toggleBold)
                        MailFormattingButton(title: "Italic", symbol: "italic", active: formatting.isItalic, action: formatting.toggleItalic)
                        MailFormattingButton(title: "Underline", symbol: "underline", active: formatting.isUnderlined, action: formatting.toggleUnderline)
                        Spacer()
                        Button(action: formatting.undo) { PostmereIcon("arrow.uturn.backward", size: 13) }
                            .buttonStyle(.borderless).disabled(!formatting.canUndo).help("Undo").accessibilityLabel("Undo signature change")
                    }.padding(.horizontal, 8).padding(.vertical, 5)
                    Divider()
                    ComposeBodyEditor(text: binding(\.text), rtfData: binding(\.rtfData), formatting: formatting,
                                      fieldLabel: "Signature for selected account")
                        .frame(height: 106)
                        .id(selectedAccountID)
                }
                .background(PostmereTheme.subtleFill, in: .rect(cornerRadius: PostmereTheme.cardRadius))
                .overlay { RoundedRectangle(cornerRadius: PostmereTheme.cardRadius).strokeBorder(PostmereTheme.rule) }
                HStack(spacing: 18) {
                    Toggle("New messages", isOn: binding(\.includeInNewMessages))
                    Toggle("Replies", isOn: binding(\.includeInReplies))
                    Toggle("Forwards", isOn: binding(\.includeInForwards))
                }.toggleStyle(.checkbox).font(.system(size: 12))
                Text("Added when you start a message from this account. Leave blank for no signature.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let error = saveError ?? preferences.loadError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .onChange(of: accounts) {
            if !accounts.contains(where: { $0.id == selectedAccountID }) { selectAccount(accounts.first?.id ?? "") }
        }
    }

    private func selectAccount(_ accountID: String) {
        selectedAccountID = accountID
        signature = preferences.signature(for: accountID)
        saveError = nil
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MailSignature, Value>) -> Binding<Value> {
        Binding(get: { signature[keyPath: keyPath] }, set: { value in
            signature[keyPath: keyPath] = value
            do {
                try preferences.save(signature, for: selectedAccountID)
                saveError = nil
            } catch { saveError = error.localizedDescription }
        })
    }

}
