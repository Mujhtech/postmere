import SwiftUI

/// Names a mail account ("Work", "Personal") so lists show the name instead
/// of repeating its address. Shown after adding an account and from Rename.
struct AccountNamingSheet: View {
    let account: BackendAccount
    let session: BackendSession
    var isNew = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private static let suggestions = ["Work", "Personal", "School", "Side project"]
    private var brand: Brand { Brand(mailProvider: account.provider) ?? .gmail }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                BrandTile(brand: brand, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "Name this account" : "Rename account")
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(account.email)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name, prompt: Text("Work, Personal…"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit(save)
                HStack(spacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        let chosen = name == suggestion
                        Button(suggestion) { name = suggestion }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: chosen ? .semibold : .regular))
                            .foregroundStyle(chosen ? palette.accentInk : Color.secondary)
                            .padding(.horizontal, 9).frame(height: 22)
                            .background(chosen ? palette.accentInk.opacity(0.10) : Color.clear, in: .capsule)
                            .overlay(Capsule().strokeBorder(chosen ? palette.accentInk.opacity(0.35) : PostmereTheme.rule))
                    }
                }
                Text("Shown in the sidebar and in From instead of the address. Recipients still see your own name.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(isNew ? "Skip" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).count > 64
                              || (isNew && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 380)
        .mailPanelSurface()
        .onAppear {
            let provided = account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            name = account.name ?? (provided.caseInsensitiveCompare(account.email) == .orderedSame ? "" : provided)
            focused = true
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await session.renameAccount(accountID: account.id, name: name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
