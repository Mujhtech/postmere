import SwiftUI
import WidgetKit

/// Unread count and the latest mail, in every Home Screen size and on the Lock Screen.
struct InboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "InboxWidget", provider: MailProvider()) { entry in
            InboxWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Inbox")
        .description("Unread mail and your latest messages.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct InboxWidgetView: View {
    let snapshot: MailWidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var tint: Color { snapshot.accent }

    var body: some View {
        Group {
            if !snapshot.isSignedIn {
                if family == .accessoryInline {
                    Label("Postmere", systemImage: "envelope")
                } else if family == .accessoryCircular || family == .accessoryRectangular {
                    Label("Sign in", systemImage: "envelope")
                } else {
                    WidgetSignedOut(tint: tint)
                }
            } else {
                switch family {
                case .systemSmall: small
                case .systemMedium: medium
                case .systemLarge: large
                case .systemExtraLarge: extraLarge
                case .accessoryCircular: circular
                case .accessoryRectangular: rectangular
                case .accessoryInline: inline
                default: small
                }
            }
        }
        .tint(tint)
        .containerBackground(for: .widget) { WidgetCanvas(tint: tint) }
        .widgetURL(PostmereLink.url(.inbox))
    }

    private var unreadLabel: String { snapshot.unread == 0 ? "All read" : "Unread" }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WidgetStamp(symbol: "tray.fill", size: 28, tint: tint)
                Spacer()
                composeButton(size: 30)
            }
            Spacer(minLength: 2)
            WidgetFigure(value: snapshot.unread, size: 46)
            Text(unreadLabel)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, -4)
            if let latest = snapshot.inbox.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(latest.sender)
                        .font(.system(size: 12, weight: .semibold))
                    Text(latest.subject)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.top, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                WidgetStamp(symbol: "tray.fill", size: 26, tint: tint)
                Spacer(minLength: 0)
                WidgetFigure(value: snapshot.unread, size: 40)
                Text(unreadLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, -3)
                if snapshot.needsReply > 0 {
                    Label("\(snapshot.needsReply) to reply", systemImage: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(WidgetInk.ember)
                        .labelStyle(.titleAndIcon)
                        .padding(.top, 6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: 84, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.inbox.isEmpty {
                    WidgetAllClear(title: "Inbox zero", tint: tint)
                } else {
                    ForEach(Array(snapshot.inbox.prefix(3).enumerated()), id: \.element.id) { index, message in
                        if index > 0 { WidgetRule(inset: 38) }
                        WidgetMessageRow(message: message, avatarSize: 28, tint: tint)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if snapshot.inbox.isEmpty {
                WidgetAllClear(title: "You’re all caught up", tint: tint)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(snapshot.inbox.prefix(5).enumerated()), id: \.element.id) { index, message in
                        if index > 0 { WidgetRule() }
                        WidgetMessageRow(message: message, showsPreview: true, avatarSize: 30, tint: tint)
                    }
                }
                Spacer(minLength: 0)
            }
            actions
        }
    }

    /// iPad: the inbox beside what needs a reply.
    private var extraLarge: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(snapshot.inbox.prefix(6).enumerated()), id: \.element.id) { index, message in
                        if index > 0 { WidgetRule() }
                        WidgetMessageRow(message: message, showsPreview: true, avatarSize: 30, tint: tint)
                    }
                    if snapshot.inbox.isEmpty { WidgetAllClear(title: "Inbox zero", tint: tint) }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Needs reply · \(snapshot.needsReply)", systemImage: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetInk.ember)
                    ForEach(Array(snapshot.needsReplyList.prefix(5).enumerated()), id: \.element.id) { index, message in
                        if index > 0 { WidgetRule() }
                        WidgetMessageRow(message: message, showsPreview: true, avatarSize: 30, tint: WidgetInk.ember)
                    }
                    if snapshot.needsReplyList.isEmpty {
                        WidgetAllClear(title: "Nothing waiting on you", tint: WidgetInk.ember)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(WidgetInk.ember.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            actions
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            WidgetStamp(symbol: "tray.fill", size: 26, tint: tint)
            Text("Inbox")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            Spacer(minLength: 4)
            if snapshot.unread > 0 {
                Text("\(snapshot.unread) unread")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.13), in: Capsule())
                    .widgetAccentable()
            }
            composeButton(size: 28)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            WidgetActionPill(title: "Compose", symbol: "square.and.pencil", route: .compose, tint: tint)
            WidgetActionPill(title: "Ask", symbol: "sparkles", route: .ask, tint: tint)
            WidgetActionPill(title: "Triage", symbol: "rectangle.stack.fill", route: .triage, tint: tint)
        }
    }

    private func composeButton(size: CGFloat) -> some View {
        Link(destination: PostmereLink.url(.compose)) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(tint.opacity(0.14), in: Circle())
                .widgetAccentable()
        }
        .accessibilityLabel("Compose")
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -1) {
                Image(systemName: "envelope.fill").font(.system(size: 11, weight: .semibold))
                Text(snapshot.unread, format: .number)
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .widgetAccentable()
        }
        .accessibilityLabel("\(snapshot.unread) unread")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "envelope.fill")
                Text("\(snapshot.unread) unread")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
            }
            .font(.system(size: 12, weight: .semibold))
            .widgetAccentable()
            if snapshot.inbox.isEmpty {
                Text("All caught up").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(snapshot.inbox.prefix(2)) { message in
                Text("\(Text(message.sender).fontWeight(.semibold)) \(message.subject)")
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        if let latest = snapshot.inbox.first(where: \.isUnread) {
            Label("\(snapshot.unread) unread · \(latest.sender)", systemImage: "envelope")
        } else {
            Label(snapshot.unread == 0 ? "Inbox zero" : "\(snapshot.unread) unread", systemImage: "envelope")
        }
    }
}

#Preview("Small", as: .systemSmall) { InboxWidget() } timeline: { MailEntry(date: .now, snapshot: .sample, relevance: nil) }
#Preview("Medium", as: .systemMedium) { InboxWidget() } timeline: { MailEntry(date: .now, snapshot: .sample, relevance: nil) }
#Preview("Large", as: .systemLarge) { InboxWidget() } timeline: { MailEntry(date: .now, snapshot: .sample, relevance: nil) }
#Preview("Rectangular", as: .accessoryRectangular) { InboxWidget() } timeline: { MailEntry(date: .now, snapshot: .sample, relevance: nil) }
