import SwiftUI

struct SpamCheckView: View {
    let message: MailMessage
    let store: MailStore
    @Environment(MailRuntime.self) private var runtime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = runtime.spamChecks.phase(for: message, session: runtime.backend)
        VStack(spacing: 0) {
            if let phase {
                SpamCheckNotice(phase: phase, canMoveToJunk: store.canMoveMessage(message, to: .junk)) {
                    runtime.spamChecks.check(message, session: runtime.backend)
                } moveToJunk: {
                    store.moveMessage(message.id, to: .junk)
                } dismiss: {
                    runtime.spamChecks.dismiss(message, session: runtime.backend)
                }
                .padding(.bottom, 14)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(y: -10).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.15), value: phase == nil)
    }
}

/// The verdict of an opt-in spam check: a scanning state, then a card whose
/// colour, icon and actions follow the verdict.
struct SpamCheckNotice: View {
    let phase: MailSpamChecks.Phase
    let canMoveToJunk: Bool
    let retry: () -> Void
    let moveToJunk: () -> Void
    let dismiss: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealKick = 0

    private enum Tone { case scanning, danger, safe, unsure, failed }

    private var tone: Tone {
        switch phase {
        case .checking: .scanning
        case .failed: .failed
        case .result(let decision):
            switch decision.verdict {
            case .possibleSpam: .danger
            case .noSpamSignals: .safe
            case .uncertain: .unsure
            }
        }
    }

    private var tint: Color {
        switch tone {
        case .scanning: palette.accentInk
        case .danger: PostmereTheme.destructiveInk
        case .safe: Color(red: 0.16, green: scheme == .dark ? 0.72 : 0.55, blue: 0.42)
        case .unsure: Color(red: scheme == .dark ? 0.92 : 0.78, green: scheme == .dark ? 0.68 : 0.52, blue: 0.12)
        case .failed: .secondary
        }
    }

    private var symbol: String {
        switch tone {
        case .scanning: "shield"
        case .danger: "exclamationmark.shield"
        case .safe: "checkmark.shield"
        case .unsure: "questionmark.shield"
        case .failed: "exclamationmark.circle"
        }
    }

    private var title: String {
        switch tone {
        case .scanning: "Checking for spam"
        case .danger: "This looks like spam"
        case .safe: "No spam signals found"
        case .unsure: "Hard to tell"
        case .failed: "Spam check unavailable"
        }
    }

    private var reason: String {
        switch phase {
        case .checking: "Reviewing the sender, links and wording."
        case .failed(let reason): reason
        case .result(let decision): decision.reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                ShieldOrb(symbol: symbol, tint: tint, scanning: tone == .scanning, kick: revealKick)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tone == .danger ? tint : .primary)
                            .accessibilityAddTraits(.isHeader)
                        if tone == .danger || tone == .safe || tone == .unsure {
                            Text("Checked by AI")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .transition(.opacity)
                        }
                        Spacer(minLength: 8)
                        if tone != .scanning && tone != .danger {
                            Button("Dismiss", action: dismiss)
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .help("Dismiss this spam check")
                                .transition(.opacity)
                        }
                    }
                    Group {
                        if tone == .scanning {
                            ShimmerText(text: reason, active: !reduceMotion)
                        } else if !reason.isEmpty {
                            Text(verbatim: reason)
                                .foregroundStyle(.secondary)
                                .lineSpacing(1.5)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.system(size: 12.5))
                    .transition(.opacity)
                    if !actions.isEmpty {
                        HStack(spacing: 8) { ForEach(actions, id: \.title) { actionButton($0) } }
                            .controlSize(.small)
                            .padding(.top, 7)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.vertical, 12)
            Rectangle().fill(.separator).frame(height: 1).accessibilityHidden(true)
        }
        .contentTransition(.opacity)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.18), value: toneKey)
        .onChange(of: toneKey) { _, _ in if tone != .scanning { revealKick += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var toneKey: String { "\(tone)" }

    // MARK: Actions

    private struct Action {
        enum Style { case primary, secondary }
        let title: String
        let style: Style
        let help: String
        let run: () -> Void
    }

    private var actions: [Action] {
        switch tone {
        case .danger:
            var list: [Action] = []
            if canMoveToJunk {
                list.append(Action(title: "Move to Junk", style: .primary,
                                   help: "Move this message to your Junk mailbox", run: moveToJunk))
            }
            list.append(Action(title: "It’s safe", style: .secondary,
                               help: "Dismiss the spam warning for this message only", run: dismiss))
            return list
        case .failed:
            return [Action(title: "Try Again", style: .secondary, help: "Run the spam check again", run: retry)]
        default:
            return []
        }
    }

    @ViewBuilder private func actionButton(_ action: Action) -> some View {
        if action.style == .primary {
            Button(action.title, action: action.run)
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .help(action.help)
        } else {
            Button(action.title, action: action.run)
                .buttonStyle(.bordered)
                .help(action.help)
        }
    }
}

// MARK: - Pieces

/// The verdict icon in a tinted disc. While checking, a highlight circles it;
/// when the verdict lands the icon swaps in with a small pop.
private struct ShieldOrb: View {
    let symbol: String
    let tint: Color
    let scanning: Bool
    let kick: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.13))
            if scanning && !reduceMotion {
                TimelineView(.animation) { context in
                    let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360
                    Circle()
                        .trim(from: 0, to: 0.32)
                        .stroke(AngularGradient(colors: [tint.opacity(0), tint], center: .center),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(angle))
                        .padding(1)
                }
                .transition(.opacity)
            }
            PostmereIcon(symbol, size: 15)
                .foregroundStyle(tint)
                .id(symbol)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
        .frame(width: 30, height: 30)
        .keyframeAnimator(initialValue: 1.0, trigger: kick) { [reduceMotion] content, scale in
            content.scaleEffect(reduceMotion ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(1.18, duration: 0.14, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
        }
        .accessibilityHidden(true)
    }
}

/// Secondary text with a light sweep passing across it while work is underway.
private struct ShimmerText: View {
    let text: String
    let active: Bool

    var body: some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .overlay {
                if active {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        GeometryReader { proxy in
                            LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: proxy.size.width * 0.35)
                                .offset(x: (proxy.size.width * 1.35) * phase - proxy.size.width * 0.35)
                        }
                    }
                    .mask(Text(verbatim: text))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
    }
}
