import AppKit
import SwiftUI

struct MenuBarInboxLabel: View {
    let runtime: MailRuntime

    var body: some View {
        let count = runtime.backend.canAccessWorkspace ? runtime.mailboxCounts.menuBarInbox?.count(for: .all) ?? 0 : 0
        let description = count == 0 ? "Postmere inbox" : "Postmere inbox, \(count.formatted()) unread"
        let symbol = NSImage(systemSymbolName: "envelope", accessibilityDescription: description)
        let envelope = symbol.map { Image(nsImage: $0) } ?? Image(systemName: "envelope")
        Group {
            if count > 0 {
                Label { Text(count > 99 ? "99+" : count.formatted()).monospacedDigit() } icon: { envelope }
                    .labelStyle(.titleAndIcon)
            } else {
                envelope
            }
        }
        .accessibilityLabel("Postmere inbox")
        .accessibilityValue(count > 0 ? "\(count.formatted()) unread" : "")
    }
}

struct MenuBarInboxHost: View {
    static let visibilityPreference = "showMenuBarInbox"

    let runtime: MailRuntime
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.mailboxColors) private var mailboxColors
    @Environment(\.colorScheme) private var scheme
    @State private var host = MenuBarPanelAnchor.Handle()

    private var sendingAccounts: [MailAccount] {
        guard runtime.backend.canAccessWorkspace, let scope = runtime.backend.scope else { return [] }
        let disconnecting = runtime.backend.disconnectingAccountIDs
        return RemoteAccountRegistry.accounts.compactMap { identity in
            guard identity.scope == scope, identity.status == "connected", !disconnecting.contains(identity.accountID) else { return nil }
            return MailAccount(rawValue: identity.localID)
        }
    }

    var body: some View {
        Group {
            if runtime.store.isOpeningMailbox || runtime.backend.isRestoring || isLoadingAccounts {
                ProgressView("Opening inbox…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 112)
            } else if runtime.backend.canAccessWorkspace, runtime.backend.accounts.isEmpty,
                      case .failed = runtime.backend.accountCatalogState {
                workspacePrompt("Mail accounts couldn’t be loaded")
            } else if runtime.backend.canAccessWorkspace {
                let connected = !sendingAccounts.isEmpty
                MenuBarInboxView(inbox: runtime.mailboxCounts.menuBarInbox, activity: runtime.mailSyncActivity,
                                 isRefreshing: runtime.isSyncingBackend, canRefresh: connected,
                                 syncError: runtime.lastMailSyncError, hasAccounts: connected,
                                 compose: compose, openInbox: openInbox, openMessage: openMessage,
                                 clearMessage: clearMessage,
                                 settings: { present { openSettings() } }, refresh: { Task { await runtime.sync() } })
                    .id(runtime.backend.scope)
            } else {
                workspacePrompt(runtime.backend.isWaitingForSavedSession ? "Waiting for your workspace" : "Sign in to see your inbox")
            }
        }
        .frame(width: MenuBarInboxView.panelWidth, alignment: .topLeading)
        .background { mailboxColors.canvas.ignoresSafeArea() }
        .background { MenuBarPanelAnchor(handle: host).frame(width: 0, height: 0) }
    }

    private func workspacePrompt(_ title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Button("Open Postmere") { present { openWindow(id: "mail") } }
        }
        .frame(maxWidth: .infinity, minHeight: 144)
    }

    private var isLoadingAccounts: Bool {
        guard runtime.backend.canAccessWorkspace, runtime.backend.accounts.isEmpty else { return false }
        switch runtime.backend.accountCatalogState {
        case .pending, .loading: return true
        case .loaded, .failed: return false
        }
    }

    private func compose() {
        let accounts = sendingAccounts
        guard let account = accounts.first(where: { $0 == runtime.store.defaultSendingAccount }) ?? accounts.first else { return }
        runtime.store.beginCompose(account: account)
        present { openWindow(id: "compose") }
    }

    private func openInbox() {
        if runtime.backend.canAccessWorkspace {
            runtime.store.selectedAccount = nil
            runtime.store.selectInboxSplit(nil)
        }
        present { openWindow(id: "mail") }
    }

    private func openMessage(_ id: UUID) {
        runtime.openMessage(id) { present { openWindow(id: "mail") } }
    }

    private func clearMessage(_ id: UUID, from filter: MenuBarInboxFilter) {
        guard runtime.backend.canAccessWorkspace, let inbox = runtime.mailboxCounts.menuBarInbox,
              inbox.messages(for: filter).contains(where: { $0.id == id }),
              let message = runtime.store.messages.first(where: { $0.id == id }),
              runtime.store.matchesMailbox(message, mailbox: .inbox) else { return }
        if filter == .needsReply {
            if message.needsReply { runtime.store.setNeedsReply(false, for: id) }
        } else if message.isUnread {
            runtime.store.setRead(true, for: [id])
        }
    }

    private func present(_ action: () -> Void) {
        host.view?.window?.close()
        NSApp.activate()
        action()
    }
}

/// The menu-bar window can be key even when a compose or settings window is already open.
private struct MenuBarPanelAnchor: NSViewRepresentable {
    @MainActor final class Handle { weak var view: NSView? }
    let handle: Handle

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        handle.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { }
}
