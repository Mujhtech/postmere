import SwiftUI

enum OnboardingMailProvider: String, CaseIterable {
    case gmail
    case outlook = "microsoft"

    var name: String { self == .gmail ? "Gmail" : "Outlook" }
    var accounts: String {
        self == .gmail ? "Google accounts and Google Workspace" : "Outlook.com and Microsoft 365"
    }
}

struct OnboardingInboxPicker: View {
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.mailboxInset) private var inset
    let session: BackendSession
    let onSync: @MainActor @Sendable () async -> Void
    /// Hands a newly added account to the onboarding window to be named, since
    /// this picker can go away as soon as the first account arrives.
    var onAccountAdded: (BackendAccount) -> Void = { _ in }
    @Environment(\.postmereAccent) private var palette
    @State private var connection = MailAccountConnection()
    @State private var hovered: OnboardingMailProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch session.accountCatalogState {
            case .pending, .loading:
                ProgressView("Checking connected accounts…").controlSize(.small)
            case let .failed(message):
                Text("Couldn’t load your accounts").font(.headline)
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try Again") {
                    Task { try? await session.refreshAccounts() }
                }
            case .loaded:
                ForEach(OnboardingMailProvider.allCases, id: \.self) { provider in
                    providerButton(provider)
                }
                if connection.provider != nil {
                    HStack {
                        Text("Finish signing in in your browser.").foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Cancel", action: connection.cancel).buttonStyle(.link)
                    }
                    .font(.callout)
                } else if let error = connection.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear(perform: connection.cancel)
        .onChange(of: connection.newAccount) { _, account in
            guard let account else { return }
            connection.newAccount = nil
            onAccountAdded(account)
        }
    }

    private func providerButton(_ provider: OnboardingMailProvider) -> some View {
        Button {
            connection.start(provider.rawValue, session: session) { await onSync() }
        } label: {
            HStack(spacing: 14) {
                OnboardingProviderMark(provider: provider)
                    .frame(width: 24, height: 24)
                    .frame(width: 40, height: 40)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.07)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.headline).foregroundStyle(.primary)
                    Text(provider.accounts).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if connection.provider == provider.rawValue {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(theme == .native ? Color(nsColor: .controlBackgroundColor) : inset, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(hovered == provider ? palette.accentInk : PostmereTheme.rule)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = provider } else if hovered == provider { hovered = nil }
        }
        .disabled(session.isBusy || connection.provider != nil)
        .accessibilityLabel("Connect \(provider.name)")
        .accessibilityHint("Opens sign-in in your browser.")
    }
}

struct OnboardingProviderMark: View {
    let provider: OnboardingMailProvider

    var body: some View {
        GeometryReader { proxy in
            BrandMark(brand: provider == .gmail ? .gmail : .outlook, size: min(proxy.size.width, proxy.size.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
