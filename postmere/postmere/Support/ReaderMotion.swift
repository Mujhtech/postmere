import SwiftUI

/// The open message is set down rather than swapped out: it tips back
/// slightly, sinks and softens while the next one rises into place.
private struct ReaderDeparture: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.06 * progress, anchor: .bottom)
            .rotation3DEffect(.degrees(7 * progress), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
            .offset(y: 34 * progress)
            .blur(radius: 6 * progress)
            .opacity(1 - progress)
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
    static var readerDeparture: AnyTransition {
        .modifier(active: ReaderDeparture(progress: 1), identity: ReaderDeparture(progress: 0))
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

    var body: some View {
        HStack(spacing: 12) {
            PostmereIcon(symbol, size: 14)
                .foregroundStyle(isTrash ? PostmereTheme.destructiveInk : palette.accentInk)
                .frame(width: 28, height: 28)
                .background((isTrash ? PostmereTheme.destructiveInk : palette.accentInk).opacity(0.12), in: Circle())
                .trashWobble(trigger: kick, enabled: !reduceMotion)
                .onAppear { if isTrash { kick += 1 } }
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
