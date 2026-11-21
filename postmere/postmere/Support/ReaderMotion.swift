import SwiftUI

/// How the open message leaves, matched to where it is going.
enum ReaderDepartureStyle {
    /// Tips back, sinks and softens, like being dropped in a bin.
    case discard
    /// Shrinks and slides down, as if filed into a box below.
    case file
    /// Drifts aside and drains of colour.
    case reject
    /// Lifts away upward, set aside for later.
    case later
    /// Rises back toward the inbox.
    case restore

    init(_ destination: Mailbox?) {
        switch destination {
        case .trash: self = .discard
        case .archive: self = .file
        case .junk: self = .reject
        case .snoozed: self = .later
        case .inbox, nil: self = .restore
        default: self = .file
        }
    }
}

/// The open message is set down rather than swapped out, in a way that
/// suggests its destination, while the next one rises into place. The style
/// is read from the store when the removal starts, since the departing view
/// was last drawn before the move.
private struct ReaderDeparture: ViewModifier {
    let progress: Double
    let store: MailStore

    func body(content: Content) -> some View {
        let p = progress
        switch ReaderDepartureStyle(store.departure?.destination) {
        case .discard:
            content
                .scaleEffect(1 - 0.06 * p, anchor: .bottom)
                .rotation3DEffect(.degrees(7 * p), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
                .offset(y: 34 * p)
                .blur(radius: 6 * p)
                .opacity(1 - p)
        case .file:
            content
                .scaleEffect(1 - 0.12 * p, anchor: .bottom)
                .offset(y: 70 * p)
                .opacity(1 - p)
        case .reject:
            content
                .saturation(1 - p)
                .rotationEffect(.degrees(-2.5 * p), anchor: .bottomLeading)
                .offset(x: -48 * p, y: 10 * p)
                .blur(radius: 3 * p)
                .opacity(1 - p)
        case .later:
            content
                .scaleEffect(1 - 0.05 * p, anchor: .top)
                .offset(y: -44 * p)
                .blur(radius: 5 * p)
                .opacity(1 - p)
        case .restore:
            content
                .scaleEffect(1 - 0.03 * p, anchor: .top)
                .offset(y: -24 * p)
                .opacity(1 - p)
        }
    }
}

private struct ReaderArrival: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.985 + 0.015 * progress, anchor: .top)
            .offset(y: 14 * (1 - progress))
            .opacity(progress)
    }
}

extension AnyTransition {
    static func readerDeparture(_ store: MailStore) -> AnyTransition {
        .modifier(active: ReaderDeparture(progress: 1, store: store), identity: ReaderDeparture(progress: 0, store: store))
    }

    static var readerArrival: AnyTransition {
        .modifier(active: ReaderArrival(progress: 0), identity: ReaderArrival(progress: 1))
    }
}

extension View {
    /// A short wobble, like a bin lid settling, each time `trigger` changes.
    func trashWobble(trigger: Int, enabled: Bool) -> some View {
        keyframeAnimator(initialValue: WobbleValues(), trigger: trigger) { content, value in
            content
                .rotationEffect(.degrees(enabled ? value.angle : 0), anchor: .bottom)
                .scaleEffect(enabled ? value.scale : 1, anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack(\.angle) {
                CubicKeyframe(-14, duration: 0.08)
                CubicKeyframe(10, duration: 0.1)
                CubicKeyframe(-5, duration: 0.1)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.18, duration: 0.12)
                SpringKeyframe(1, duration: 0.4, spring: .bouncy)
            }
        }
    }
}

struct WobbleValues {
    var angle = 0.0
    var scale = 1.0
    var x = 0.0
    var y = 0.0
}

/// The small reaction a toolbar or toast icon gives when its action happens.
enum ActionKick {
    case trash, archive, junk, restore, snooze, star

    init?(_ destination: Mailbox?) {
        switch destination {
        case .trash: self = .trash
        case .archive: self = .archive
        case .junk: self = .junk
        case .snoozed: self = .snooze
        case .inbox, nil: self = .restore
        default: return nil
        }
    }
}

extension View {
    /// Plays `kind`'s reaction each time `trigger` changes.
    @ViewBuilder func actionKick(_ kind: ActionKick, trigger: Int, enabled: Bool) -> some View {
        switch kind {
        case .trash: trashWobble(trigger: trigger, enabled: enabled)
        case .archive:
            // Drops into the box and settles.
            kick(trigger: trigger, enabled: enabled) {
                KeyframeTrack(\.y) {
                    CubicKeyframe(-4, duration: 0.09); CubicKeyframe(3, duration: 0.12)
                    SpringKeyframe(0, duration: 0.35, spring: .bouncy)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.14, duration: 0.09); CubicKeyframe(0.9, duration: 0.12)
                    SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                }
            }
        case .junk:
            // A firm side-to-side "no".
            kick(trigger: trigger, enabled: enabled) {
                KeyframeTrack(\.x) {
                    CubicKeyframe(-4, duration: 0.06); CubicKeyframe(4, duration: 0.08)
                    CubicKeyframe(-3, duration: 0.08); CubicKeyframe(2, duration: 0.08)
                    SpringKeyframe(0, duration: 0.25)
                }
            }
        case .restore:
            // Lifts up out of the tray.
            kick(trigger: trigger, enabled: enabled) {
                KeyframeTrack(\.y) {
                    CubicKeyframe(3, duration: 0.08); CubicKeyframe(-4, duration: 0.14)
                    SpringKeyframe(0, duration: 0.35, spring: .bouncy)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(0.92, duration: 0.08); CubicKeyframe(1.12, duration: 0.14)
                    SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                }
            }
        case .snooze:
            // Rocks gently, like something nodding off.
            kick(trigger: trigger, enabled: enabled) {
                KeyframeTrack(\.angle) {
                    CubicKeyframe(-18, duration: 0.14); CubicKeyframe(12, duration: 0.18)
                    CubicKeyframe(-6, duration: 0.16); SpringKeyframe(0, duration: 0.4, spring: .smooth)
                }
                KeyframeTrack(\.y) {
                    CubicKeyframe(-3, duration: 0.2); SpringKeyframe(0, duration: 0.5, spring: .smooth)
                }
            }
        case .star:
            // Pops and twinkles.
            kick(trigger: trigger, enabled: enabled) {
                KeyframeTrack(\.scale) {
                    CubicKeyframe(0.7, duration: 0.07); CubicKeyframe(1.35, duration: 0.14)
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                }
                KeyframeTrack(\.angle) {
                    CubicKeyframe(-16, duration: 0.1); CubicKeyframe(14, duration: 0.14)
                    SpringKeyframe(0, duration: 0.35, spring: .bouncy)
                }
            }
        }
    }

    private func kick(trigger: Int, enabled: Bool,
                      @KeyframesBuilder<WobbleValues> _ keyframes: @escaping () -> some Keyframes<WobbleValues>) -> some View {
        keyframeAnimator(initialValue: WobbleValues(), trigger: trigger) { content, value in
            content
                .rotationEffect(.degrees(enabled ? value.angle : 0))
                .scaleEffect(enabled ? value.scale : 1)
                .offset(x: enabled ? value.x : 0, y: enabled ? value.y : 0)
        } keyframes: { _ in keyframes() }
    }
}

/// Confirms a mailbox action with what happened, to which message, and a
/// generous Undo whose countdown pauses while the pointer rests on it.
struct ActionToast: View {
    let store: MailStore
    let action: String
    let detail: String?
    let offersUndo: Bool
    let onExpire: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remaining: Double = 1
    @State private var hovering = false
    @State private var kick = 0

    private static let duration = 6.0

    private var symbol: String {
        let text = action.lowercased()
        if text.contains("trash") { return "trash" }
        if text.contains("archive") { return "archivebox" }
        if text.contains("junk") { return "exclamationmark.shield" }
        if text.contains("inbox") || text.contains("restored") || text.contains("undone") { return "tray.and.arrow.down" }
        if text.contains("star") { return "star" }
        if text.contains("snooze") { return "moon.zzz" }
        return "checkmark"
    }

    private var isTrash: Bool { symbol == "trash" }

    private var toastKick: ActionKick {
        switch symbol {
        case "trash": .trash
        case "archivebox": .archive
        case "exclamationmark.shield": .junk
        case "tray.and.arrow.down": .restore
        case "star": .star
        case "moon.zzz": .snooze
        default: .archive
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            PostmereIcon(symbol, size: 14)
                .foregroundStyle(isTrash ? PostmereTheme.destructiveInk : palette.accentInk)
                .frame(width: 28, height: 28)
                .background((isTrash ? PostmereTheme.destructiveInk : palette.accentInk).opacity(0.12), in: Circle())
                .actionKick(toastKick, trigger: kick, enabled: !reduceMotion)
                .onAppear { kick += 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(action).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 260, alignment: .leading)
            if offersUndo {
                Button(action: store.undoLastMove) {
                    HStack(spacing: 7) {
                        Text("Undo").font(.system(size: 12.5, weight: .semibold))
                        ZStack {
                            Circle().stroke(palette.accentInk.opacity(0.2), lineWidth: 2)
                            Circle()
                                .trim(from: 0, to: remaining)
                                .stroke(palette.accentInk, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 13, height: 13)
                    }
                    .foregroundStyle(palette.accentInk)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(palette.accentInk.opacity(hovering ? 0.16 : 0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Undo")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, offersUndo ? 8 : 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(PostmereTheme.rule.opacity(0.8)))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .task(id: action) { await countDown() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([action, detail].compactMap { $0 }.joined(separator: ", "))
    }

    /// Counts down in small steps, holding still while hovered.
    private func countDown() async {
        remaining = 1
        let step = 0.05
        while remaining > 0 {
            try? await Task.sleep(for: .seconds(step))
            if Task.isCancelled { return }
            guard !hovering else { continue }
            withAnimation(.linear(duration: step)) { remaining = max(0, remaining - step / Self.duration) }
        }
        onExpire()
    }
}
