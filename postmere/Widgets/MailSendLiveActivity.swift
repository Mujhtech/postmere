import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// A message on its way out, on the Lock Screen and in the Dynamic Island: the undo
/// countdown with an Undo button, a scheduled time, sending, then sent.
struct MailSendLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MailSendActivityAttributes.self) { context in
            SendLockScreenView(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(Color(rgb: context.attributes.accentRGB))
                .widgetURL(PostmereLink.url(.message(context.attributes.messageID)))
        } dynamicIsland: { context in
            let tint = Color(rgb: context.attributes.accentRGB)
            let phase = SendPhase(context: context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SendGlyph(phase: phase, tint: tint, size: 44)
                        .padding(.leading, 4)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SendClock(context: context, phase: phase, tint: tint)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .padding(.trailing, 6)
                        .padding(.top, 10)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title(to: context.attributes.recipient))
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(context.attributes.subject.isEmpty ? "No subject" : context.attributes.subject)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        SendProgress(context: context, phase: phase, tint: tint)
                        if phase.canUndo {
                            UndoButton(messageID: context.attributes.messageID, tint: tint, compact: false)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                }
            } compactLeading: {
                SendGlyph(phase: phase, tint: tint, size: 22)
            } compactTrailing: {
                SendClock(context: context, phase: phase, tint: tint)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: 46)
            } minimal: {
                SendGlyph(phase: phase, tint: tint, size: 22)
            }
            .keylineTint(tint)
            .widgetURL(PostmereLink.url(.message(context.attributes.messageID)))
        }
    }
}

/// What the activity is showing, including "the undo window has closed" while the
/// app sleeps: a stale activity has moved on to sending by itself.
enum SendPhase: Equatable {
    case undo(until: Date)
    case scheduled(at: Date)
    case sending
    case sent
    case failed(String?)

    init(context: ActivityViewContext<MailSendActivityAttributes>) {
        let state = context.state
        let now = Date.now
        switch state.phase {
        case .undo where state.undoUntil > now && !context.isStale: self = .undo(until: state.undoUntil)
        case .undo, .scheduled:
            self = state.scheduledAt > now && !(context.isStale && state.phase == .scheduled)
                ? .scheduled(at: state.scheduledAt) : .sending
        case .sending: self = .sending
        case .sent: self = .sent
        case .failed: self = .failed(state.detail)
        }
    }

    var canUndo: Bool {
        switch self {
        case .undo, .scheduled: true
        default: false
        }
    }

    var symbol: String {
        switch self {
        case .undo: "paperplane.fill"
        case .scheduled: "clock.fill"
        case .sending: "paperplane.fill"
        case .sent: "checkmark"
        case .failed: "exclamationmark"
        }
    }

    func title(to recipient: String) -> String {
        switch self {
        case .undo: "Sending to \(recipient)"
        case .scheduled(let date): "To \(recipient) · \(date.formatted(date: .omitted, time: .shortened))"
        case .sending: "Sending to \(recipient)…"
        case .sent: "Sent to \(recipient)"
        case .failed: "Couldn’t send to \(recipient)"
        }
    }
}

/// The phase's glyph on a round accent badge.
struct SendGlyph: View {
    let phase: SendPhase
    let tint: Color
    var size: CGFloat

    private var color: Color {
        switch phase {
        case .sent: Color(red: 0.24, green: 0.66, blue: 0.40)
        case .failed: Color(red: 0.86, green: 0.30, blue: 0.28)
        default: tint
        }
    }

    var body: some View {
        Image(systemName: phase.symbol)
            .font(.system(size: size * 0.44, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// A live countdown to the undo deadline or the scheduled time, or a short status word.
struct SendClock: View {
    let context: ActivityViewContext<MailSendActivityAttributes>
    let phase: SendPhase
    let tint: Color

    var body: some View {
        switch phase {
        case .undo(let until):
            Text(timerInterval: Date.now...until, countsDown: true, showsHours: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint)
        case .scheduled(let date):
            Text(date, style: .timer)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint)
        case .sending:
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(tint)
        case .sent:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.24, green: 0.66, blue: 0.40))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(red: 0.86, green: 0.30, blue: 0.28))
        }
    }
}

/// How much of the wait has passed, drawn by the system so it moves while the app sleeps.
struct SendProgress: View {
    let context: ActivityViewContext<MailSendActivityAttributes>
    let phase: SendPhase
    let tint: Color

    var body: some View {
        Group {
            switch phase {
            case .undo(let until):
                ProgressView(timerInterval: min(context.state.queuedAt, until)...until, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(tint)
            case .scheduled(let date):
                Label("Sends \(date.formatted(.relative(presentation: .named)))", systemImage: "calendar.badge.clock")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            case .sending:
                ProgressView(value: 0.85).tint(tint)
            case .sent:
                ProgressView(value: 1).tint(Color(red: 0.24, green: 0.66, blue: 0.40))
            case .failed(let detail):
                Text(detail ?? "Open Postmere to retry")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Takes the message back. Runs in the app through `UndoSendIntent`.
struct UndoButton: View {
    let messageID: UUID
    let tint: Color
    var compact: Bool

    var body: some View {
        Button(intent: UndoSendIntent(messageID: messageID)) {
            Label("Undo", systemImage: "arrow.uturn.backward")
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .padding(.horizontal, compact ? 12 : 14)
                .padding(.vertical, compact ? 7 : 8)
                .foregroundStyle(tint)
                .background(tint.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The Lock Screen banner.
struct SendLockScreenView: View {
    let context: ActivityViewContext<MailSendActivityAttributes>
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = Color(rgb: context.attributes.accentRGB)
        let phase = SendPhase(context: context)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                SendGlyph(phase: phase, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase.title(to: context.attributes.recipient))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(context.attributes.subject.isEmpty ? "No subject" : context.attributes.subject)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                SendClock(context: context, phase: phase, tint: tint)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .frame(maxWidth: 80, alignment: .trailing)
            }
            HStack(spacing: 12) {
                SendProgress(context: context, phase: phase, tint: tint)
                if phase.canUndo {
                    UndoButton(messageID: context.attributes.messageID, tint: tint, compact: true)
                }
            }
        }
        .padding(16)
        .background {
            ZStack {
                (scheme == .dark ? WidgetInk.paperDark : WidgetInk.paperLight).opacity(0.92)
                RadialGradient(colors: [tint.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 240)
            }
        }
    }
}

#Preview("Undo", as: .content, using: MailSendActivityAttributes(messageID: UUID(), recipient: "Ada Okafor",
                                                                   subject: "Design review moved to Thursday",
                                                                   accentRGB: 0x498775)) {
    MailSendLiveActivity()
} contentStates: {
    MailSendActivityAttributes.ContentState(phase: .undo, queuedAt: .now, undoUntil: .now.addingTimeInterval(10),
                                            scheduledAt: .now.addingTimeInterval(10))
    MailSendActivityAttributes.ContentState(phase: .sent, queuedAt: .now, undoUntil: .now, scheduledAt: .now)
}
