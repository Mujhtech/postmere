import SwiftUI

struct SpamCheckView: View {
    let message: MailMessage
    let store: MailStore
    @Environment(MailRuntime.self) private var runtime

    var body: some View {
        if let phase = runtime.spamChecks.phase(for: message, session: runtime.backend) {
            SpamCheckNotice(phase: phase, canMoveToJunk: store.canMoveMessage(message, to: .junk)) {
                runtime.spamChecks.check(message, session: runtime.backend)
            } moveToJunk: {
                store.moveMessage(message.id, to: .junk)
            } dismiss: {
                runtime.spamChecks.dismiss(message, session: runtime.backend)
            }
            .padding(.bottom, 14)
        }
    }
}

struct SpamCheckNotice: View {
    let phase: MailSpamChecks.Phase
    let canMoveToJunk: Bool
    let retry: () -> Void
    let moveToJunk: () -> Void
    let dismiss: () -> Void
    @Environment(\.mailboxInset) private var inset
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            switch phase {
            case .checking:
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Checking for spam…").font(.callout)
            case .failed(let reason):
                icon("exclamationmark.circle", color: .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    description("Spam check unavailable", reason: reason)
                    HStack(spacing: 12) {
                        Button("Try Again", action: retry)
                        dismissButton
                    }
                }
            case .result(let decision):
                switch decision.verdict {
                case .possibleSpam:
                    icon("exclamationmark.shield.fill", color: PostmereTheme.destructiveInk)
                    VStack(alignment: .leading, spacing: 6) {
                        description("Possible spam", reason: decision.reason)
                        HStack(spacing: 12) {
                            if canMoveToJunk {
                                Button("Move to Junk", action: moveToJunk)
                                    .help("Move this message to your Junk mailbox")
                            }
                            Button(action: dismiss) { Text("Looks safe").foregroundStyle(palette.accentInk) }
                                .buttonStyle(.borderless)
                                .help("Dismiss the spam warning for this message only")
                        }
                    }
                case .noSpamSignals:
                    result("No spam signals found", icon: "shield", reason: decision.reason)
                case .uncertain:
                    result("Spam check inconclusive", icon: "questionmark.circle", reason: decision.reason)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: 600, alignment: .leading)
        .background(inset, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private func result(_ title: LocalizedStringKey, icon symbol: String, reason: String) -> some View {
        Group {
            icon(symbol, color: .secondary)
            VStack(alignment: .leading, spacing: 6) {
                description(title, reason: reason)
                dismissButton
            }
        }
    }

    private func description(_ title: LocalizedStringKey, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if !reason.isEmpty {
                Text(verbatim: reason).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func icon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium)).foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var dismissButton: some View {
        Button(action: dismiss) { Text("Dismiss").foregroundStyle(palette.accentInk) }
            .buttonStyle(.borderless)
            .help("Dismiss this spam check")
    }
}
