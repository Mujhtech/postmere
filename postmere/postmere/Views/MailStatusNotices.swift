import SwiftUI

struct MailStatusNotices: View {
    let store: MailStore
    var pendingMailLinks: MailLinkDrafts?

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let links = pendingMailLinks, links.hasPending,
               store.isComposing || store.draftRecoveryAvailable || MailAccount.sendingAccounts.isEmpty {
                let pendingDraft = store.isComposing || store.draftRecoveryAvailable
                notice(pendingDraft ? "Finish your current draft to open the email link."
                       : "Connect a mail account to open the email link.", symbol: "envelope") {
                    Button("Dismiss", action: links.dismissNext)
                }
            }
            if let error = store.persistenceError {
                notice(error, symbol: "externaldrive.badge.exclamationmark", isError: true) {
                    Button("Retry", action: store.retryPersistence)
                }
            }
            if let error = store.operationError {
                notice(error, symbol: "exclamationmark.circle", isError: true) {
                    Button {
                        store.operationError = nil
                    } label: {
                        PostmereIcon("xmark", size: 11)
                            .frame(width: 24, height: 24)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss notice")
                    .accessibilityLabel("Dismiss notice")
                }
            }
            if store.draftRecoveryAvailable {
                notice("An unfinished message was recovered.", symbol: "doc") {
                    Button("Resume", action: store.recoverDraft)
                    Button("Discard", role: .destructive, action: store.discardRecoveredDraft)
                }
            }
            if store.latestUndoableSend != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let item = store.latestUndoableSend {
                        let description = item.scheduledAt > item.undoUntil
                            ? "Scheduled for \(item.scheduledAt.formatted(date: .abbreviated, time: .shortened))"
                            : "Message queued · sending in \(max(0, Int(ceil(item.undoUntil.timeIntervalSinceNow)))) seconds"
                        notice(description, symbol: "paperplane") {
                            Button("Undo Send", action: store.undoLastSend)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 460, alignment: .trailing)
        .padding([.horizontal, .bottom], 12)
    }

    private func notice<Actions: View>(_ message: String, symbol: String, isError: Bool = false,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 9) {
            PostmereIcon(symbol, size: 16)
                .foregroundStyle(isError ? Color.red : PostmereTheme.icon)
            Text(message)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(isError ? "Error. \(message)" : message)
            HStack(spacing: 6) { actions() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .toastSurface()
        .accessibilityElement(children: .contain)
        .padding(.top, 6)
    }
}

extension View {
    /// The one surface every toast and notice uses: Liquid Glass with soft
    /// rounded ends, so confirmations and errors look like the same family.
    func toastSurface() -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }
}
