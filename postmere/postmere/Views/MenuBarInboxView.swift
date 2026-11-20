import AppKit
import SwiftUI

struct MenuBarInboxView: View {
    static let panelWidth: CGFloat = 390

    let inbox: MenuBarInbox?
    let activity: MailSyncActivity
    let isRefreshing: Bool
    let canRefresh: Bool
    var syncError: String? = nil
    let hasAccounts: Bool
    let compose: () -> Void
    let openInbox: () -> Void
    let openMessage: (UUID) -> Void
    let clearMessage: (UUID, MenuBarInboxFilter) -> Void
    let settings: () -> Void
    let refresh: () -> Void

    @Environment(\.postmereAccent) private var accent
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @AppStorage("showMessagePreviews") private var showMessagePreviews = true
    @State private var filter: MenuBarInboxFilter = .all
    @FocusState private var focusedMessage: UUID?
    @FocusState private var focusedFilter: MenuBarInboxFilter?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inbox")
                        .font(.system(size: 26, weight: .medium, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    if hasAccounts, let inbox {
                        Text(filter.summary(inbox.count(for: filter)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Button(action: compose) {
                    Label("Compose", systemImage: "square.and.pencil")
                        .foregroundStyle(hasAccounts ? accent.accentInk : Color.secondary)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(!hasAccounts)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if hasAccounts {
                filterBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Divider()
            messages
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(minWidth: 0, idealWidth: Self.panelWidth, maxWidth: Self.panelWidth, alignment: .leading)
        .background {
            if theme != .native { theme.colors(for: scheme).canvas }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarInboxFilter.allCases, id: \.self) { option in
                let count = inbox?.count(for: option)
                let selected = filter == option
                Button {
                    filter = option
                } label: {
                    HStack(spacing: 4) {
                        Text(option.menuTitle)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        if let count {
                            Text(verbatim: count > 99 ? "99+" : count.formatted())
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(selected ? accent.selectionSecondaryInk : .secondary)
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(selected ? accent.selectionInk : .primary)
                    .frame(minWidth: 0, maxWidth: option == .all ? 64 : .infinity, minHeight: 26)
                    .background(selected ? accent.selectionFill : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focused($focusedFilter, equals: option)
                .accessibilityLabel(option.menuTitle)
                .accessibilityValue(count.map(option.summary) ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("menuBarInbox.filter." + option.rawValue)
            }
        }
        .padding(2)
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inbox filters")
        .onMoveCommand { direction in
            let options = MenuBarInboxFilter.allCases
            guard let focusedFilter, let index = options.firstIndex(of: focusedFilter) else { return }
            let next: Int
            switch direction {
            case .left: next = max(options.startIndex, index - 1)
            case .right: next = min(options.endIndex - 1, index + 1)
            default: return
            }
            self.focusedFilter = options[next]
            filter = options[next]
        }
    }

    @ViewBuilder private var messages: some View {
        if !hasAccounts {
            placeholder("Connect a mail account", symbol: "tray")
        } else if let inbox {
            let recent = inbox.messages(for: filter)
            let height = listHeight(for: inbox)
            if recent.isEmpty {
                placeholder(filter.emptyTitle, symbol: filter == .needsReply ? "arrowshape.turn.up.left" : "tray")
                    .frame(height: height)
            } else {
                ScrollView {
                    messageRows(recent)
                }
                .id(filter)
                .frame(height: height)
            }
        } else {
            ProgressView("Loading inbox…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 90)
        }
    }

    private func listHeight(for inbox: MenuBarInbox) -> CGFloat {
        // This window stays anchored under its status item while switching filters.
        let rowCount = MenuBarInboxFilter.allCases.map { inbox.messages(for: $0).count }.max() ?? 0
        let rowHeight: CGFloat = showMessagePreviews ? 63 : 47
        let rowsHeight = max(108, CGFloat(rowCount) * rowHeight + 8)
        let smallestScreen = NSScreen.screens.map(\.visibleFrame.height).min() ?? 700
        return min(rowsHeight, max(90, smallestScreen - 180))
    }

    private func messageRows(_ recent: [MailMessage]) -> some View {
        VStack(spacing: 0) {
            ForEach(recent) { message in
                MenuBarMessageRow(message: message, filter: filter, showMessagePreviews: showMessagePreviews,
                                  focusedMessage: $focusedMessage, open: { openMessage(message.id) }, clear: { clearMessage(message.id, filter) })
                if message.id != recent.last?.id {
                    Divider().padding(.leading, 48).padding(.trailing, 8)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onMoveCommand { direction in
            guard let index = recent.firstIndex(where: { $0.id == focusedMessage }) else { return }
            switch direction {
            case .up: focusedMessage = recent[max(recent.startIndex, index - 1)].id
            case .down: focusedMessage = recent[min(recent.endIndex - 1, index + 1)].id
            default: break
            }
        }
    }

    private func placeholder(_ title: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if hasAccounts {
                if activity.isActive || isRefreshing {
                    HStack(spacing: 6) {
                        if case .waiting = activity {
                            Image(systemName: "clock")
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text(statusTitle).lineLimit(1)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(statusHelp)
                    .help(statusHelp)
                } else {
                    Button(action: refresh) {
                        Label(statusTitle, systemImage: syncError == nil ? "arrow.clockwise" : "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(accent.accentInk)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canRefresh)
                    .help(statusHelp)
                }
            }
            Spacer(minLength: 2)
            Button(action: settings) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Settings")
            Divider().frame(height: 14)
            Button(action: openInbox) {
                HStack(spacing: 5) {
                    Text(hasAccounts ? "Open Inbox" : "Open Postmere")
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(accent.accentInk)
            }
            .buttonStyle(.borderless)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var statusTitle: String {
        if activity.isActive { return [activity.title, activity.detail].compactMap { $0 }.joined(separator: " · ") }
        if isRefreshing { return "Checking mail…" }
        return syncError == nil ? "Refresh" : "Retry sync"
    }

    private var statusHelp: String {
        if activity.isActive { return activity.explanation }
        if isRefreshing { return "Checking for new mail" }
        return syncError.map { "Sync failed. \($0)" } ?? "Check for new mail"
    }

}

private struct MenuBarMessageRow: View {
    let message: MailMessage
    let filter: MenuBarInboxFilter
    let showMessagePreviews: Bool
    let focusedMessage: FocusState<UUID?>.Binding
    let open: () -> Void
    let clear: () -> Void
    @FocusState private var actionFocused: Bool
    @State private var hovering = false
    @Environment(\.postmereAccent) private var accent

    private var sender: String { message.sender.isEmpty ? message.senderEmail : message.sender }

    private var timestamp: String {
        if Calendar.current.isDateInToday(message.sentAt) {
            return message.sentAt.formatted(date: .omitted, time: .shortened)
        }
        return message.sentAt.formatted(.dateTime.month(.abbreviated).day())
    }

    private var showsAction: Bool { hovering || focusedMessage.wrappedValue == message.id || actionFocused }
    private var actionTitle: String { filter == .needsReply ? "Mark Done" : "Mark as Read" }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            messageButton
            Button(action: clear) {
                Group {
                    if showsAction {
                        Image(systemName: filter == .needsReply ? "checkmark.circle" : "envelope.open")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(accent.accentInk)
                    } else {
                        Text(verbatim: timestamp).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 26, minHeight: 22, alignment: .trailing)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focused($actionFocused)
            .accessibilityLabel(actionTitle)
            .accessibilityHint(message.displaySubject)
            .help(actionTitle)
            .padding(.top, 3)
            .padding(.trailing, 8)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private var messageButton: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ParticipantPhoto(address: message.senderEmail, name: sender, size: 30, verifiedMark: message.currentSenderMark)
                    .overlay(alignment: .bottomTrailing) {
                        if message.isUnread {
                            Circle().fill(accent.accentInk).frame(width: 7, height: 7)
                                .overlay { Circle().stroke(.background, lineWidth: 1) }
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: sender)
                            .font(.body.weight(message.isUnread ? .semibold : .medium))
                            .lineLimit(1)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: timestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 26, alignment: .trailing)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .hidden()
                    }
                    Text(verbatim: message.displaySubject)
                        .lineLimit(1)
                        .font(.callout)
                    if showMessagePreviews && !message.displayPreview.isEmpty {
                        Text(verbatim: message.displayPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(hovering ? accent.selectionFill.opacity(0.55) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focused(focusedMessage, equals: message.id)
        .accessibilityLabel("\(sender), \(message.displaySubject)")
        .accessibilityValue("\(message.isUnread ? "Unread" : "Read"), \(message.sentAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityAction(named: Text(actionTitle), clear)
        .help(message.displaySubject)
    }
}

private extension MenuBarInboxFilter {
    var menuTitle: String {
        switch self {
        case .all: "All"
        case .people: "People"
        case .updates: "Updates"
        case .needsReply: "Needs Reply"
        }
    }

    func summary(_ count: Int) -> String {
        switch self {
        case .all: "\(count.formatted()) unread"
        case .people: "\(count.formatted()) unread from people"
        case .updates: "\(count.formatted()) unread \(count == 1 ? "update" : "updates")"
        case .needsReply: "\(count.formatted()) awaiting your reply"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "No unread mail"
        case .people: "No unread mail from people"
        case .updates: "No unread updates"
        case .needsReply: "No conversations need a reply"
        }
    }
}
