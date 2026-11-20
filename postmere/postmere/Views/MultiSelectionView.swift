import SwiftUI

/// Reader content for a multi-message selection: a fanned preview of what is
/// selected, the count, and a dock of bulk actions that adapt to the selection.
struct MultiSelectionView: View {
    let store: MailStore

    @Environment(\.postmereAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: DockAction?

    var body: some View {
        let messages = store.selectedMessages
        let count = store.selectedMessageIDs.count
        VStack(spacing: 0) {
            SelectionCardStack(messages: Array(messages.prefix(3)), count: count)
            countTitle(count)
                .padding(.top, 30)
            if let senders = sendersLine(messages) {
                Text(senders)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 6)
            }
            ActionDock(actions: actions(messages, ids: store.selectedMessageIDs), hovered: $hovered,
                       snooze: { store.snoozeMessages(store.selectedMessageIDs, until: $0) })
                .padding(.top, 28)
            caption
                .padding(.top, 14)
        }
        .frame(maxWidth: 520)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.18), value: count)
        .onExitCommand { store.clearSelection() }
    }

    // MARK: Summary

    private func countTitle(_ count: Int) -> some View {
        VStack(spacing: 2) {
            Text(count.formatted())
                .font(.system(size: 56, weight: .semibold, design: .serif))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
            Text(count == 1 ? "message selected" : "messages selected")
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(accent.accentInk)
        }
        .accessibilityElement(children: .combine)
    }

    private func sendersLine(_ messages: [MailMessage]) -> String? {
        var seen = Set<String>()
        let names = messages.compactMap { message -> String? in
            guard seen.insert(message.senderEmail.lowercased()).inserted else { return nil }
            return message.sender.isEmpty ? message.senderEmail : message.sender
        }
        switch names.count {
        case 0: return nil
        case 1: return "All from \(names[0])"
        case 2: return "From \(names[0]) and \(names[1])"
        default:
            let others = names.count - 2
            return "From \(names[0]), \(names[1]) and \(others) \(others == 1 ? "other" : "others")"
        }
    }

    /// Names the hovered action; otherwise reminds how to leave the selection.
    private var caption: some View {
        ZStack {
            if let hovered {
                HStack(spacing: 6) {
                    Text(hovered.title)
                    if let shortcut = hovered.shortcut { KeyCap(shortcut) }
                }
                .foregroundStyle(hovered.role == .destructive ? PostmereTheme.destructiveInk : .primary)
                .transition(.opacity.combined(with: .offset(y: 3)))
                .id(hovered.id)
            } else {
                Button(action: store.clearSelection) {
                    HStack(spacing: 6) {
                        KeyCap("esc")
                        Text("to deselect")
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deselect all")
                .transition(.opacity)
            }
        }
        .font(.callout)
        .frame(height: 20)
        .animation(.easeOut(duration: 0.15), value: hovered?.id)
    }

    // MARK: Actions

    private func actions(_ messages: [MailMessage], ids: Set<UUID>) -> [[DockAction]] {
        let allRead = !messages.isEmpty && messages.allSatisfy { !$0.isUnread }
        let allStarred = !messages.isEmpty && messages.allSatisfy(\.isStarred)
        let workflow = messages.filter(\.allowsWorkflowActions)
        let allNeedReply = !workflow.isEmpty && workflow.allSatisfy(\.needsReply)
        let allJunk = !messages.isEmpty && messages.allSatisfy { $0.mailbox == .junk }
        let canMove = { (mailbox: Mailbox) in messages.contains { store.canMoveMessage($0, to: mailbox) } }
        return [
            [
                DockAction(id: "archive", title: "Archive", symbol: "archivebox", shortcut: "E", role: .primary,
                           enabled: canMove(.archive)) { store.moveMessages(ids, to: .archive) },
                DockAction(id: "trash", title: "Move to Trash", symbol: "trash", shortcut: "#", role: .destructive,
                           enabled: canMove(.trash)) { store.moveMessages(ids, to: .trash) },
            ],
            [
                DockAction(id: "read", title: allRead ? "Mark as Unread" : "Mark as Read",
                           symbol: allRead ? "envelope" : "envelope.open") { store.setRead(!allRead, for: ids) },
                DockAction(id: "star", title: allStarred ? "Remove Stars" : "Star", symbol: allStarred ? "star.fill" : "star",
                           shortcut: "S") { store.setStarred(!allStarred, for: ids) },
                DockAction(id: "reply", title: allNeedReply ? "Mark Done" : "Needs Reply",
                           symbol: allNeedReply ? "checkmark.circle" : "arrowshape.turn.up.left",
                           enabled: !workflow.isEmpty) { store.setNeedsReply(!allNeedReply, for: ids) },
                DockAction(id: "snooze", title: "Snooze", symbol: "moon.zzz", isSnooze: true,
                           enabled: !workflow.isEmpty) {},
            ],
            [
                allJunk
                    ? DockAction(id: "junk", title: "Not Junk", symbol: "shield") { store.moveMessages(ids, to: .inbox) }
                    : DockAction(id: "junk", title: "Move to Junk", symbol: "exclamationmark.shield",
                                 enabled: canMove(.junk)) { store.moveMessages(ids, to: .junk) },
                DockAction(id: "inbox", title: "Move to Inbox", symbol: "tray",
                           enabled: !allJunk && canMove(.inbox)) { store.moveMessages(ids, to: .inbox) },
            ],
        ]
    }
}

private struct DockAction: Identifiable {
    enum Role { case standard, primary, destructive }
    let id: String
    let title: String
    let symbol: String
    var shortcut: String?
    var role = Role.standard
    var isSnooze = false
    var enabled = true
    let perform: () -> Void
}

// MARK: - Dock

/// A floating capsule of icon buttons, grouped by kind of action.
private struct ActionDock: View {
    let actions: [[DockAction]]
    @Binding var hovered: DockAction?
    let snooze: (Date) -> Void

    @Environment(\.mailboxInset) private var inset

    var body: some View {
        HStack(spacing: 4) {
            ForEach(actions.indices, id: \.self) { group in
                if group > 0 {
                    Capsule().fill(PostmereTheme.rule).frame(width: 1, height: 22).padding(.horizontal, 6)
                }
                ForEach(actions[group]) { action in
                    item(action)
                }
            }
        }
        .padding(6)
        .background(PostmereTheme.paper, in: Capsule())
        .background(inset.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(PostmereTheme.rule))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
        .onHover { if !$0 { hovered = nil } }
    }

    @ViewBuilder private func item(_ action: DockAction) -> some View {
        let isHovered = hovered?.id == action.id
        Group {
            if action.isSnooze {
                Menu {
                    ForEach(SnoozePreset.allCases, id: \.self) { preset in
                        Button(preset.title) { snooze(preset.date()) }
                    }
                } label: {
                    DockIcon(action: action, isHovered: isHovered)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(DockButtonStyle())
            } else {
                Button(action: action.perform) { DockIcon(action: action, isHovered: isHovered) }
                    .buttonStyle(DockButtonStyle())
            }
        }
        .disabled(!action.enabled)
        .onHover { inside in
            if inside, action.enabled { hovered = action } else if isHovered { hovered = nil }
        }
        .help(action.shortcut.map { "\(action.title) (\($0))" } ?? action.title)
        .accessibilityLabel(action.title)
    }
}

private struct DockIcon: View {
    let action: DockAction
    let isHovered: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.postmereAccent) private var accent

    private var tint: Color {
        switch action.role {
        case .destructive: PostmereTheme.destructiveInk
        case .primary: isHovered ? accent.selectionInk : accent.accentInk
        case .standard: isHovered ? accent.selectionInk : .primary
        }
    }

    private var fill: Color {
        guard isHovered else { return .clear }
        return action.role == .destructive ? PostmereTheme.destructiveInk.opacity(0.12) : accent.selectionFill
    }

    var body: some View {
        PostmereIcon(action.symbol, size: 18)
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(fill, in: Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

private struct DockButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.35), value: configuration.isPressed)
    }
}

// MARK: - Card stack

/// Up to three selected messages fanned like a hand of cards, with the total
/// count pinned to the front card.
private struct SelectionCardStack: View {
    let messages: [MailMessage]
    let count: Int

    @Environment(\.postmereAccent) private var accent

    private static let tilts: [Double] = [0, -5, 4.5]
    private static let offsets: [CGSize] = [.zero, CGSize(width: -14, height: -12), CGSize(width: 16, height: -20)]

    var body: some View {
        ZStack {
            ForEach(Array(messages.enumerated()).reversed(), id: \.element.id) { index, message in
                SelectionCard(message: message, isFront: index == 0)
                    .rotationEffect(.degrees(Self.tilts[index]), anchor: .bottom)
                    .offset(Self.offsets[index])
                    .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .frame(width: 300, height: 104)
        .accessibilityElement()
        .accessibilityLabel("\(count) selected messages")
    }
}

private struct SelectionCard: View {
    let message: MailMessage
    let isFront: Bool

    @Environment(\.postmereAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            MailParticipantAvatar(address: message.senderEmail, name: message.sender, size: 30, messageID: message.id)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if message.isUnread {
                        Circle().fill(accent.accent).frame(width: 6, height: 6)
                    }
                    Text(message.sender.isEmpty ? message.senderEmail : message.sender)
                        .font(.system(size: 12, weight: message.isUnread ? .semibold : .medium))
                        .lineLimit(1)
                }
                Text(message.subject.isEmpty ? "No subject" : message.subject)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 270, height: 62)
        .background(PostmereTheme.paper, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PostmereTheme.rule))
        .shadow(color: .black.opacity(isFront ? 0.12 : 0.06), radius: isFront ? 12 : 6, y: isFront ? 6 : 3)
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(PostmereTheme.rule))
            .accessibilityHidden(true)
    }
}

// MARK: - Snooze presets

private enum SnoozePreset: CaseIterable {
    case laterToday, tomorrow, weekend, nextWeek

    var title: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrow: "Tomorrow morning"
        case .weekend: "This weekend"
        case .nextWeek: "Next week"
        }
    }

    func date(from now: Date = .now, calendar: Calendar = .current) -> Date {
        func next(weekday: Int) -> Date {
            calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: weekday),
                              matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
        }
        switch self {
        case .laterToday:
            return now.addingTimeInterval(3 * 3600)
        case .tomorrow:
            let day = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        case .weekend:
            return next(weekday: 7)
        case .nextWeek:
            return next(weekday: 2)
        }
    }
}
