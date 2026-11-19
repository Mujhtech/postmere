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
        Canvas { context, size in
            let unit = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * unit) / 2, y: (size.height - 24 * unit) / 2)
            context.scaleBy(x: unit, y: unit)
            switch provider {
            case .gmail:
                func fill(_ color: Color, _ points: [CGPoint]) {
                    var outline = Path()
                    outline.addLines(points)
                    outline.closeSubpath()
                    context.fill(outline, with: .color(color))
                }
                let blue = Color(red: 0.26, green: 0.52, blue: 0.96)
                let green = Color(red: 0.20, green: 0.66, blue: 0.33)
                let red = Color(red: 0.92, green: 0.26, blue: 0.21)
                let yellow = Color(red: 0.98, green: 0.74, blue: 0.02)
                fill(blue, [.init(x: 0, y: 7), .init(x: 4.5, y: 10.5), .init(x: 4.5, y: 21), .init(x: 0, y: 21)])
                fill(green, [.init(x: 19.5, y: 10.5), .init(x: 24, y: 7), .init(x: 24, y: 21), .init(x: 19.5, y: 21)])
                fill(red, [.init(x: 0, y: 3), .init(x: 3, y: 3), .init(x: 12, y: 10), .init(x: 21, y: 3),
                           .init(x: 21, y: 9.5), .init(x: 12, y: 16.5), .init(x: 0, y: 7.5)])
                fill(yellow, [.init(x: 19.5, y: 4.2), .init(x: 21, y: 3), .init(x: 24, y: 3),
                              .init(x: 24, y: 7.5), .init(x: 19.5, y: 11)])
            case .outlook:
                let colors = [Color(red: 0.95, green: 0.31, blue: 0.13),
                              Color(red: 0.50, green: 0.73, blue: 0),
                              Color(red: 0, green: 0.64, blue: 0.94),
                              Color(red: 1, green: 0.73, blue: 0)]
                for (index, color) in colors.enumerated() {
                    let rect = CGRect(x: index % 2 * 13, y: index / 2 * 13, width: 11, height: 11)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
