import SwiftUI

/// One pass through a set of conversations: a fixed queue, where the user is,
/// and what they decided, so a decision can be undone and summarized.
@MainActor @Observable
final class TriageSession {
    enum Decision: String, CaseIterable {
        case archive, trash, snooze, reply, needsReply, skip

        var title: String {
            switch self {
            case .archive: "Archived"
            case .trash: "Trashed"
            case .snooze: "Snoozed"
            case .reply: "Replied"
            case .needsReply: "Needs reply"
            case .skip: "Skipped"
            }
        }
    }

    let title: String
    let ids: [UUID]
    private(set) var index = 0
    private(set) var decisions: [(id: UUID, decision: Decision)] = []
    /// How the current card leaves; read by the transition as it departs.
    private(set) var exit: Decision = .skip
    /// Undo brings the previous card back from the side it left.
    private(set) var isReturning = false

    init(title: String, ids: [UUID]) {
        self.title = title
        self.ids = ids
    }

    var currentID: UUID? { ids.indices.contains(index) ? ids[index] : nil }
    var isFinished: Bool { index >= ids.count }
    var progress: Double { ids.isEmpty ? 1 : Double(min(index, ids.count)) / Double(ids.count) }

    func count(of decision: Decision) -> Int { decisions.count { $0.decision == decision } }

    /// Records the decision, then advances on the next frame so the departing
    /// card is drawn with this decision's exit before it leaves.
    func decide(_ decision: Decision) {
        guard let id = currentID else { return }
        decisions.append((id, decision))
        exit = decision
        isReturning = false
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.42, bounce: 0.12)) { self.index += 1 }
        }
    }

    func undo() -> (id: UUID, decision: Decision)? {
        guard let last = decisions.popLast() else { return nil }
        exit = last.decision
        isReturning = true
        withAnimation(.spring(duration: 0.42, bounce: 0.15)) { index = max(0, index - 1) }
        return last
    }
}

/// A focused, one-conversation-at-a-time pass over the mail window.
struct TriageView: View {
    let session: TriageSession
    let store: MailStore
    let close: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var choosingSnooze = false

    private var message: MailMessage? {
        session.currentID.flatMap { id in store.messages.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if session.isFinished {
                    TriageSummary(session: session, close: close)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if let message {
                    card(message)
                        .id(message.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: session.isReturning ? .triageExit(session.exit) : .triageArrival,
                            removal: .triageExit(session.exit)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            if !session.isFinished { actionBar }
        }
        .background(PostmereTheme.paper)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down, action: handleKey)
        .onChange(of: session.currentID, initial: true) { _, id in
            choosingSnooze = false
            // Opening the conversation loads its body and marks it read, as reading would.
            if let id, let message = store.messages.first(where: { $0.id == id }) { store.select(message) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Triage")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                PostmereIcon("xmark", size: 11).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(PostmereTheme.rule.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Leave triage · Esc")
            .accessibilityLabel("Leave triage")
            VStack(alignment: .leading, spacing: 1) {
                Text("Triage").font(.system(size: 13, weight: .semibold))
                Text(session.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.isFinished ? "Done" : "\(session.index + 1) of \(session.ids.count)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(session.index)))
            GeometryReader { proxy in
                Capsule().fill(PostmereTheme.rule.opacity(0.6))
                    .overlay(alignment: .leading) {
                        Capsule().fill(palette.accent).frame(width: proxy.size.width * session.progress)
                    }
            }
            .frame(width: 120, height: 4)
            .animation(.spring(duration: 0.45, bounce: 0.1), value: session.progress)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Card

    private func card(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 40,
                                 verifiedMark: store.displayedSenderMark(for: message))
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.sender).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(message.senderEmail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(message.sentAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(message.displaySubject)
                .font(.system(size: 24, weight: .medium, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            if !message.attachments.isEmpty {
                Label("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            Divider().padding(.vertical, 16)
            ScrollView {
                Text(verbatim: bodyText(message))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .padding(28)
        .frame(maxWidth: 680, maxHeight: 560, alignment: .topLeading)
        .background(PostmereTheme.paper, in: .rect(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 28, y: 12)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        .padding(.vertical, 12)
    }

    private func bodyText(_ message: MailMessage) -> String {
        let text = message.paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? message.displayPreview : text
    }

    // MARK: Actions

    private var actionBar: some View {
        Group {
            if choosingSnooze {
                HStack(spacing: 8) {
                    Text("Snooze until").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(Array(snoozeChoices.enumerated()), id: \.offset) { index, choice in
                        TriageKey(title: choice.title, key: "\(index + 1)") { snooze(until: choice.date) }
                    }
                    TriageKey(title: "Cancel", key: "esc") { choosingSnooze = false }
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            } else {
                HStack(spacing: 8) {
                    TriageKey(title: "Archive", key: "E", symbol: "archivebox") { act(.archive) }
                    TriageKey(title: "Trash", key: "#", symbol: "trash", destructive: true) { act(.trash) }
                    TriageKey(title: "Snooze", key: "S", symbol: "moon.zzz") { withAnimation(.snappy) { choosingSnooze = true } }
                    TriageKey(title: "Reply", key: "R", symbol: "arrowshape.turn.up.left") { act(.reply) }
                    TriageKey(title: "Needs reply", key: "H", symbol: "bell") { act(.needsReply) }
                    TriageKey(title: "Skip", key: "␣", symbol: "chevron.right") { act(.skip) }
                    TriageKey(title: "Undo", key: "Z", symbol: "arrow.uturn.backward") { undo() }
                        .disabled(session.decisions.isEmpty)
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.22), value: choosingSnooze)
    }

    private var snoozeChoices: [(title: String, date: Date)] {
        let calendar = Calendar.current
        let now = Date.now
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3 * 3600)
        let laterToday = evening > now.addingTimeInterval(3600) ? evening : now.addingTimeInterval(3 * 3600)
        let tomorrow = calendar.date(bySettingHour: 8, minute: 0, second: 0,
                                     of: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ?? now
        let nextWeek = calendar.date(bySettingHour: 8, minute: 0, second: 0,
                                     of: calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? now) ?? now
        return [("Later today", laterToday), ("Tomorrow", tomorrow), ("Next week", nextWeek)]
    }

    private func act(_ decision: TriageSession.Decision) {
        guard let message else { return }
        switch decision {
        case .archive:
            guard store.canMoveMessage(message, to: .archive) else { return }
            store.moveMessage(message.id, to: .archive)
        case .trash:
            guard store.canMoveMessage(message, to: .trash) else { return }
            store.moveMessage(message.id, to: .trash)
        case .reply:
            store.beginReplyAll(message)
        case .needsReply:
            store.setNeedsReply(true, for: message.id)
        case .snooze, .skip:
            break
        }
        session.decide(decision)
    }

    private func snooze(until date: Date) {
        guard let message else { return }
        store.snoozeMessage(message.id, until: date)
        choosingSnooze = false
        session.decide(.snooze)
    }

    private func undo() {
        guard let last = session.undo() else { return }
        switch last.decision {
        case .archive, .trash: store.undoLastMove()
        case .snooze: store.unsnoozeMessage(last.id)
        case .needsReply: store.setNeedsReply(false, for: last.id)
        case .reply, .skip: break
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            if choosingSnooze { choosingSnooze = false } else { close() }
            return .handled
        }
        if session.isFinished {
            if press.key == .return { close(); return .handled }
            if press.characters.lowercased() == "z" { undo(); return .handled }
            return .ignored
        }
        if choosingSnooze, let digit = Int(press.characters), (1...snoozeChoices.count).contains(digit) {
            snooze(until: snoozeChoices[digit - 1].date)
            return .handled
        }
        if press.key == .space || press.key == .rightArrow { act(.skip); return .handled }
        if press.key == .leftArrow || (press.characters.lowercased() == "z" && press.modifiers.isEmpty) { undo(); return .handled }
        if press.modifiers.contains(.command), press.characters.lowercased() == "z" { undo(); return .handled }
        if press.key == .delete { act(.trash); return .handled }
        switch press.characters.lowercased() {
        case "e": act(.archive)
        case "#": act(.trash)
        case "s": withAnimation(.snappy) { choosingSnooze = true }
        case "r": act(.reply)
        case "h": act(.needsReply)
        default: return .ignored
        }
        return .handled
    }
}

// MARK: - Pieces

private struct TriageKey: View {
    let title: String
    let key: String
    var symbol: String?
    var destructive = false
    let action: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    PostmereIcon(symbol, size: 13)
                        .foregroundStyle(destructive ? PostmereTheme.destructiveInk : palette.accentInk)
                }
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(key)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(PostmereTheme.rule.opacity(0.7), in: .rect(cornerRadius: 4))
            }
            .padding(.leading, symbol == nil ? 12 : 10)
            .padding(.trailing, 7)
            .frame(height: 32)
            .background(hovering ? palette.selectionFill : PostmereTheme.rule.opacity(0.25),
                        in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(TriageKeyStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(title) · \(key)")
    }
}

private struct TriageKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Shown when the queue is done: what was decided, and the way back.
private struct TriageSummary: View {
    let session: TriageSession
    let close: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(palette.accent.opacity(0.12)).frame(width: 72, height: 72)
                    .scaleEffect(drawn || reduceMotion ? 1 : 0.6)
                PostmereIcon("checkmark", size: 28).foregroundStyle(palette.accentInk)
                    .scaleEffect(drawn || reduceMotion ? 1 : 0.3)
                    .opacity(drawn || reduceMotion ? 1 : 0)
            }
            .padding(.bottom, 4)
            Text("All done").font(.system(size: 30, weight: .medium, design: .serif))
            Text("You went through \(session.ids.count) conversation\(session.ids.count == 1 ? "" : "s").")
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ForEach(TriageSession.Decision.allCases, id: \.self) { decision in
                    let count = session.count(of: decision)
                    if count > 0 {
                        VStack(spacing: 2) {
                            Text(count.formatted())
                                .font(.system(size: 20, weight: .semibold, design: .serif))
                                .monospacedDigit()
                            Text(decision.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 8)
            Button("Back to Inbox", action: close)
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 14)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.45).delay(0.1)) { drawn = true }
        }
    }
}

// MARK: - Motion

private struct TriageCardMotion: ViewModifier {
    let decision: TriageSession.Decision
    let progress: Double

    func body(content: Content) -> some View {
        let p = progress
        switch decision {
        case .archive:
            content.scaleEffect(1 - 0.12 * p, anchor: .bottom).offset(y: 90 * p).opacity(1 - p)
        case .trash:
            content
                .scaleEffect(1 - 0.08 * p, anchor: .bottom)
                .rotation3DEffect(.degrees(9 * p), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
                .offset(y: 60 * p)
                .blur(radius: 6 * p)
                .opacity(1 - p)
        case .snooze:
            content.scaleEffect(1 - 0.06 * p, anchor: .top).offset(y: -90 * p).blur(radius: 4 * p).opacity(1 - p)
        case .needsReply, .reply:
            content.rotationEffect(.degrees(3 * p), anchor: .bottomTrailing).offset(x: 160 * p).opacity(1 - p)
        case .skip:
            content.rotationEffect(.degrees(-3 * p), anchor: .bottomLeading).offset(x: -160 * p).opacity(1 - p)
        }
    }
}

private struct TriageArrival: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.94 + 0.06 * progress)
            .offset(y: 18 * (1 - progress))
            .opacity(progress)
    }
}

private extension AnyTransition {
    static func triageExit(_ decision: TriageSession.Decision) -> AnyTransition {
        .modifier(active: TriageCardMotion(decision: decision, progress: 1),
                  identity: TriageCardMotion(decision: decision, progress: 0))
    }

    static var triageArrival: AnyTransition {
        .modifier(active: TriageArrival(progress: 0), identity: TriageArrival(progress: 1))
    }
}
