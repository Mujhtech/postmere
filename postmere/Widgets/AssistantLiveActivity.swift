import ActivityKit
import SwiftUI
import WidgetKit

/// What a connected assistant is doing in the user's mail, live: on the Lock
/// Screen and in the Dynamic Island while it works, then a short summary.
struct AssistantLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AssistantActivityAttributes.self) { context in
            AssistantLockScreenView(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(AssistantInk.accent)
                .widgetURL(URL(string: "postmere://assistants"))
        } dynamicIsland: { context in
            let state = context.state
            let working = state.working && !context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AssistantBadge(name: context.attributes.clientName, working: working, size: 44)
                        .padding(.leading, 4)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(state.calls, format: .number)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText(value: Double(state.calls)))
                            .foregroundStyle(AssistantInk.accent)
                        Text(state.calls == 1 ? "action" : "actions")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.clientName)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        AssistantNowLine(state: state, working: working)
                            .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AssistantTrail(state: state, working: working)
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                }
            } compactLeading: {
                AssistantBadge(name: context.attributes.clientName, working: working, size: 22)
            } compactTrailing: {
                Image(systemName: working ? AssistantToolWording.symbol(state.tool) : "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(working ? AssistantInk.accent : AssistantInk.done)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: working)
            } minimal: {
                AssistantBadge(name: context.attributes.clientName, working: working, size: 22)
            }
            .keylineTint(AssistantInk.accent)
            .widgetURL(URL(string: "postmere://assistants"))
        }
    }
}

enum AssistantInk {
    /// The app's accent, as the widgets last saw it.
    static var accent: Color { (MailWidgetSnapshot.load() ?? .signedOut).accent }
    static let done = Color(red: 0.24, green: 0.66, blue: 0.40)
}

/// The assistant's own logo on its brand tile, as in the app, or its initial on
/// the accent. Ringed while it works.
struct AssistantBadge: View {
    let name: String
    let working: Bool
    var size: CGFloat

    /// The logo in the widget's asset catalog and its tile colour; mirrors the app's `Brand`.
    private var brand: (asset: String, tile: Color, fullColor: Bool)? {
        let lower = name.lowercased()
        if lower.contains("claude") { return ("claude", Color(red: 0.851, green: 0.467, blue: 0.341), false) }
        if lower.contains("codex") || lower.contains("chatgpt") || lower.contains("openai") {
            return ("openai", Color(red: 0.255, green: 0.161, blue: 0.569), false)
        }
        if lower.contains("cursor") { return ("cursor", .black, false) }
        if lower.contains("vs code") || lower.contains("vscode") || lower.contains("visual studio code") { return ("vscode", .white, true) }
        return nil
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Group {
            if let brand {
                Image("Brands/\(brand.asset)")
                    .resizable()
                    .renderingMode(brand.fullColor ? .original : .template)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: size * (brand.fullColor ? 0.74 : 0.56), height: size * (brand.fullColor ? 0.74 : 0.56))
                    .frame(width: size, height: size)
                    .background(brand.tile.gradient, in: shape)
            } else {
                Text(name.first.map { String($0).uppercased() } ?? "A")
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(AssistantInk.accent.gradient, in: shape)
            }
        }
        .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
        .overlay {
            if working {
                RoundedRectangle(cornerRadius: size * 0.27 + size * 0.12, style: .continuous)
                    .strokeBorder(AssistantInk.accent.opacity(0.7), lineWidth: max(1.5, size * 0.06))
                    .padding(-size * 0.12)
            }
        }
        .padding(working ? size * 0.12 : 0)
        .accessibilityHidden(true)
    }
}

/// "Reading a message · 2:14", or "Done · 12 actions".
struct AssistantNowLine: View {
    let state: AssistantActivityAttributes.ContentState
    let working: Bool

    var body: some View {
        HStack(spacing: 5) {
            if working {
                Image(systemName: AssistantToolWording.symbol(state.tool))
                    .foregroundStyle(AssistantInk.accent)
                    .symbolEffect(.pulse, options: .repeating)
                Text(AssistantToolWording.doing(state.tool))
                    .lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                Text(state.startDate, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AssistantInk.done)
                Text("Done · \(state.calls) \(state.calls == 1 ? "action" : "actions")")
                    .lineLimit(1)
            }
        }
        .contentTransition(.opacity)
    }
}

/// The last few things it did, newest first, as small chips.
struct AssistantTrail: View {
    let state: AssistantActivityAttributes.ContentState
    let working: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(state.recent.prefix(3).enumerated()), id: \.offset) { index, tool in
                Label(AssistantToolWording.summary(tool), systemImage: AssistantToolWording.symbol(tool))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(index == 0 && working ? AnyShapeStyle(AssistantInk.accent) : AnyShapeStyle(.secondary))
                    .background((index == 0 && working ? AssistantInk.accent : Color.secondary).opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

struct AssistantLockScreenView: View {
    let context: ActivityViewContext<AssistantActivityAttributes>
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let state = context.state
        let working = state.working && !context.isStale
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AssistantBadge(name: context.attributes.clientName, working: working, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(context.attributes.clientName)
                            .font(.system(size: 15.5, weight: .semibold))
                            .lineLimit(1)
                        Text(working ? "in your mail" : "finished")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    AssistantNowLine(state: state, working: working)
                        .font(.system(size: 13.5))
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(state.calls, format: .number)
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                        .contentTransition(.numericText(value: Double(state.calls)))
                    Text(state.calls == 1 ? "action" : "actions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            AssistantTrail(state: state, working: working)
        }
        .padding(16)
        .background {
            ZStack {
                (scheme == .dark ? WidgetInk.paperDark : WidgetInk.paperLight).opacity(0.92)
                RadialGradient(colors: [AssistantInk.accent.opacity(working ? 0.24 : 0.12), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 240)
            }
        }
    }
}

#Preview("Working", as: .content, using: AssistantActivityAttributes(grantID: UUID().uuidString, clientName: "Claude Code")) {
    AssistantLiveActivity()
} contentStates: {
    AssistantActivityAttributes.ContentState(tool: "read_message", recent: ["read_message", "list_messages", "list_accounts"],
                                             calls: 7, startedAt: Date.now.addingTimeInterval(-95).timeIntervalSince1970,
                                             lastAt: Date.now.timeIntervalSince1970, working: true)
    AssistantActivityAttributes.ContentState(tool: "create_draft", recent: ["create_draft", "read_message"],
                                             calls: 12, startedAt: Date.now.addingTimeInterval(-300).timeIntervalSince1970,
                                             lastAt: Date.now.timeIntervalSince1970, working: false)
}
