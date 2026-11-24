import AppIntents
import SwiftUI
import WidgetKit

/// Conversations waiting on you.
struct NeedsReplyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NeedsReplyWidget", provider: MailProvider()) { entry in
            NeedsReplyWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Needs Reply")
        .description("Conversations waiting on your answer.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct NeedsReplyWidgetView: View {
    let snapshot: MailWidgetSnapshot
    @Environment(\.widgetFamily) private var family
    private let tint = WidgetInk.ember

    var body: some View {
        Group {
            if !snapshot.isSignedIn {
                if family == .accessoryCircular || family == .accessoryRectangular {
                    Label("Sign in", systemImage: "arrowshape.turn.up.left")
                } else {
                    WidgetSignedOut(tint: snapshot.accent)
                }
            } else {
                switch family {
                case .systemMedium: medium
                case .accessoryCircular: circular
                case .accessoryRectangular: rectangular
                default: small
                }
            }
        }
        .tint(tint)
        .containerBackground(for: .widget) { WidgetCanvas(tint: tint, glowAt: .topTrailing) }
        .widgetURL(PostmereLink.url(.needsReply))
    }

    private var waitingLabel: String {
        snapshot.needsReply == 0 ? "Nothing waiting" : snapshot.needsReply == 1 ? "Waiting on you" : "Waiting on you"
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WidgetStamp(symbol: "arrowshape.turn.up.left.fill", size: 28, tint: tint)
                Spacer()
                if !snapshot.needsReplyList.isEmpty {
                    WidgetAvatarStack(messages: snapshot.needsReplyList, size: 24)
                }
            }
            Spacer(minLength: 2)
            if snapshot.needsReply == 0 {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(tint)
                    .widgetAccentable()
                Text("All answered")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .padding(.top, 4)
            } else {
                WidgetFigure(value: snapshot.needsReply, size: 46)
                Text(waitingLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, -4)
                if let first = snapshot.needsReplyList.first {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.sender).font(.system(size: 12, weight: .semibold))
                        Text("since \(first.sentAt, format: .relativeShort)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .padding(.top, 7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                WidgetStamp(symbol: "arrowshape.turn.up.left.fill", size: 24, tint: tint)
                Text("Needs reply")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                Spacer()
                if snapshot.needsReply > 0 {
                    Text(snapshot.needsReply, format: .number)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.14), in: Capsule())
                        .widgetAccentable()
                }
            }
            if snapshot.needsReplyList.isEmpty {
                WidgetAllClear(title: "Nothing waiting on you", tint: tint)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(snapshot.needsReplyList.prefix(3).enumerated()), id: \.element.id) { index, message in
                        if index > 0 { WidgetRule(inset: 38) }
                        WidgetMessageRow(message: message, avatarSize: 28, tint: tint)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -1) {
                Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 11, weight: .semibold))
                Text(snapshot.needsReply, format: .number)
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                    .minimumScaleFactor(0.5)
            }
            .widgetAccentable()
        }
        .accessibilityLabel("\(snapshot.needsReply) need a reply")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                Text("\(snapshot.needsReply) to reply")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
            }
            .font(.system(size: 12, weight: .semibold))
            .widgetAccentable()
            if snapshot.needsReplyList.isEmpty {
                Text("Nothing waiting").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(snapshot.needsReplyList.prefix(2)) { message in
                Text("\(Text(message.sender).fontWeight(.semibold)) \(message.subject)")
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quick actions

/// Compose, Ask, Triage and Needs Reply, one tap from the Home or Lock Screen.
struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickActionsWidget", provider: MailProvider()) { entry in
            QuickActionsView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Quick Actions")
        .description("Write, ask, triage or reply in one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

struct QuickActionsView: View {
    let snapshot: MailWidgetSnapshot
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    private struct Action: Identifiable {
        let title: String
        let symbol: String
        let route: PostmereLink.Route
        let color: Color?
        var id: String { title }
    }

    private var actions: [Action] {
        [Action(title: "Compose", symbol: "square.and.pencil", route: .compose, color: nil),
         Action(title: "Ask", symbol: "sparkles", route: .ask, color: Color(red: 0.45, green: 0.38, blue: 0.78)),
         Action(title: "Triage", symbol: "rectangle.stack.fill", route: .triage, color: Color(red: 0.22, green: 0.51, blue: 0.68)),
         Action(title: "Reply", symbol: "arrowshape.turn.up.left.fill", route: .needsReply, color: WidgetInk.ember)]
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .semibold))
                }
                .widgetURL(PostmereLink.url(.compose))
                .accessibilityLabel("Compose")
            case .systemMedium:
                HStack(spacing: 8) {
                    ForEach(actions) { action in tile(action, tall: true) }
                }
            default:
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { tile(actions[0]); tile(actions[1]) }
                    GridRow { tile(actions[2]); tile(actions[3]) }
                }
            }
        }
        .tint(snapshot.accent)
        .containerBackground(for: .widget) { WidgetCanvas(tint: snapshot.accent) }
    }

    private func tile(_ action: Action, tall: Bool = false) -> some View {
        let color = action.color ?? snapshot.accent
        return Link(destination: PostmereLink.url(action.route)) {
            VStack(spacing: tall ? 9 : 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: tall ? 17 : 15, weight: .semibold))
                    .foregroundStyle(mode == .fullColor ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: tall ? 40 : 34, height: tall ? 40 : 34)
                    .background {
                        Circle().fill(mode == .fullColor
                                      ? AnyShapeStyle(LinearGradient(colors: [color.mix(with: .white, by: 0.15), color],
                                                                     startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(.primary.opacity(0.15)))
                    }
                    .overlay(alignment: .topTrailing) {
                        if action.route == .needsReply && snapshot.needsReply > 0 {
                            Text(snapshot.needsReply, format: .number)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(Color.red, in: Capsule())
                                .offset(x: 6, y: -4)
                        }
                    }
                    .widgetAccentable()
                Text(action.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityLabel(action.title)
    }
}

// MARK: - Controls

/// Control Center, Lock Screen and Action button.
struct ComposeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "mujhtech.postmere.compose") {
            ControlWidgetButton(action: OpenURLIntent(PostmereLink.url(.compose))) {
                Label("New Email", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Email")
        .description("Start a new message in Postmere.")
    }
}

struct AskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "mujhtech.postmere.ask") {
            ControlWidgetButton(action: OpenURLIntent(PostmereLink.url(.ask))) {
                Label("Ask Mail", systemImage: "sparkles")
            }
        }
        .displayName("Ask Mail")
        .description("Ask a question about your mail.")
    }
}

struct TriageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "mujhtech.postmere.triage") {
            ControlWidgetButton(action: OpenURLIntent(PostmereLink.url(.triage))) {
                Label("Triage Inbox", systemImage: "rectangle.stack")
            }
        }
        .displayName("Triage Inbox")
        .description("Go through unread mail one at a time.")
    }
}
