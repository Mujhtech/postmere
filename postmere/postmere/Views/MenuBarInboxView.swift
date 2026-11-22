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
    let act: (MenuBarRowAction, UUID, MenuBarInboxFilter) -> Void
    let settings: () -> Void
    let refresh: () -> Void

    @Environment(\.postmereAccent) private var accent
    @Environment(\.mailboxTheme) private var theme
    @Environment(\.mailboxColors) private var mailboxColors
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

            if hasAccounts, let code = latestCode {
                codeCard(code)
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
            if theme != .native { mailboxColors.canvas }
        }
    }

    // MARK: Verification code

    /// The newest sign-in code from the last 15 minutes, if any.
    private var latestCode: (message: MailMessage, code: String)? {
        guard let inbox else { return nil }
        let cutoff = Date.now.addingTimeInterval(-15 * 60)
        for message in inbox.messages(for: .all) where message.sentAt >= cutoff {
            if let code = MailVerificationCode.detect(subject: message.subject, paragraphs: message.paragraphs,
                                                      html: message.bodyHTML, preview: message.displayPreview) {
                return (message, code)
            }
        }
        return nil
    }

    private func codeCard(_ found: (message: MailMessage, code: String)) -> some View {
        MenuBarCodeCard(sender: found.message.sender.isEmpty ? found.message.senderEmail : found.message.sender,
                        code: found.code, sentAt: found.message.sentAt) {
            act(.clear, found.message.id, .all)
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
                    .background(selected ? accent.selectionFill : .clear, in: .capsule)
                    .contentShape(.capsule)
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
        .background(.quaternary.opacity(0.5), in: .capsule)
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
                placeholder(filter.emptyTitle, symbol: filter == .needsYou ? "arrowshape.turn.up.left" : "tray")
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
                                  focusedMessage: $focusedMessage, open: { openMessage(message.id) },
                                  act: { action in act(action, message.id, filter) })
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
    let act: (MenuBarRowAction) -> Void
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
    private var actionTitle: String { filter == .needsYou ? "Mark Done" : "Mark as Read" }
    private var clear: () -> Void { { act(.clear) } }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            messageButton
            Group {
                if showsAction {
                    // Quick actions in place of the time: archive, snooze, read or done.
                    HStack(spacing: 2) {
                        rowAction("Archive", symbol: "archivebox") { act(.archive) }
                        Menu {
                            ForEach(Self.snoozeChoices, id: \.title) { choice in
                                Button(choice.title) { act(.snooze(choice.date())) }
                            }
                        } label: {
                            Image(systemName: "moon.zzz").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(accent.accentInk)
                                .frame(width: 24, height: 22)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Snooze")
                        .accessibilityLabel("Snooze")
                        rowAction(actionTitle, symbol: filter == .needsYou ? "checkmark.circle" : "envelope.open", action: clear)
                            .focused($actionFocused)
                    }
                    .padding(.horizontal, 3)
                    .background(.regularMaterial, in: .capsule)
                    .transition(.opacity)
                } else {
                    Button(action: clear) {
                        Text(verbatim: timestamp).font(.caption).foregroundStyle(.secondary)
                            .frame(minWidth: 26, minHeight: 22, alignment: .trailing)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .focused($actionFocused)
                    .accessibilityLabel(actionTitle)
                    .accessibilityHint(message.displaySubject)
                }
            }
            .padding(.top, 3)
            .padding(.trailing, 8)
        }
        .animation(.easeOut(duration: 0.12), value: showsAction)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private func rowAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent.accentInk)
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint(message.displaySubject)
    }

    private static let snoozeChoices: [(title: String, date: () -> Date)] = [
        ("Later Today", {
            let calendar = Calendar.current
            let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now
            return evening > .now.addingTimeInterval(3_600) ? evening : .now.addingTimeInterval(3 * 3_600)
        }),
        ("Tomorrow Morning", {
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }),
        ("Next Week", {
            let calendar = Calendar.current
            let monday = calendar.nextDate(after: .now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? .now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: monday) ?? monday
        }),
    ]

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
        case .needsYou: "Needs You"
        }
    }

    func summary(_ count: Int) -> String {
        switch self {
        case .all: "\(count.formatted()) unread"
        case .people: "\(count.formatted()) unread from people"
        case .updates: "\(count.formatted()) unread \(count == 1 ? "update" : "updates")"
        case .needsYou: "\(count.formatted()) waiting on you"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "No unread mail"
        case .people: "No unread mail from people"
        case .updates: "No unread updates"
        case .needsYou: "Nothing is waiting on you"
        }
    }
}

/// A fresh sign-in code at the top of the menu bar: copy it without opening
/// the message. Copying marks the message read.
private struct MenuBarCodeCard: View {
    let sender: String
    let code: String
    let sentAt: Date
    let copied: () -> Void
    @Environment(\.postmereAccent) private var accent
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Code from \(sender)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(verbatim: code)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                withAnimation(.snappy(duration: 0.2)) { didCopy = true }
                copied()
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(accent.accentInk.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
        .help("Received \(sentAt.formatted(.relative(presentation: .named)))")
    }
}
